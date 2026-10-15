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
    var options = Host.Options.withFrameCap(frame_cap);
    options.codec = codec_id;
    var relay = test_host.init(allocator, @as([32]u8, @splat(0x81)), options);
    defer relay.deinit();
    var home = test_host.init(allocator, @as([32]u8, @splat(0x82)), options);
    defer home.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x83)), options);
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const home_pair = try openPair(allocator, &relay, &home, "127.0.0.1:7181", &dials);
    const recipient_pair = try openPair(allocator, &relay, &recipient, "127.0.0.1:7182", &dials);

    // The relay already holds a promise imported from the home session. Giving
    // that Host identity to another session creates one introducing-session
    // proxy and one home listener.
    const source_export = try home_pair.b.served.port.peer.session_state.allocatePromiseExport();
    try home_pair.a.served.port.peer.session_state.registerImport(.from(source_export.int()));
    const source_token = try relay.node.enrollForeign(
        home_pair.a.peer_handle,
        .{ .far = model.FarRef.promise(source_export.int()) },
    );
    const projected = (try relay.node.proxyForeignPromiseFulfill(
        recipient_pair.a.peer_handle,
        source_token.routed.id,
    )).?;
    const recipient_import = model.ImportPosition.from(projected.near.export_position.int());

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

    const settled = recipient_pair.a.served.port.peer.session_state.importedPromiseResolution(
        recipient_import,
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
