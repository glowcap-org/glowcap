//! The shipped transport archives through the C driver: the TCP package
//! installs atomically with keyed-tcp and noise-tcp profiles, and the relay
//! archive owns clear and sealed rendezvous as one package, dialing an
//! authenticated noise-relay session.

const std = @import("std");
const wait = @import("../../support/wait.zig");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const crelay = @import("c_abi_net_transport_relay");
const ctcp = @import("c_abi_net_transport_tcp");
const glowcap = @import("glowcap");
const ws_relay = @import("../../support/ws_relay.zig");

const harness = @import("harness.zig");
const residents = @import("residents.zig");
const typed_resident = @import("typed_resident.zig");
const default_tcp_config = harness.default_tcp_config;
const close_cancel = harness.close_cancel;
const providerFailure = harness.providerFailure;
const expectOk = harness.expectOk;
const expectStep = harness.expectStep;
const readListenerLocator = harness.readListenerLocator;
const expectLoopReadable = harness.expectLoopReadable;
const directAddresses = harness.directAddresses;
const dialParts = harness.dialParts;
const dialLocator = harness.dialLocator;
const advertiseParts = harness.advertiseParts;
const newLoop = harness.newLoop;
const Drained = harness.Drained;
const serveBoth = harness.serveBoth;
const drainEvents = harness.drainEvents;
const listenReady = harness.listenReady;
const injectedMultiplexedConnectionFailure = residents.injectedMultiplexedConnectionFailure;
const widgetBehavior = typed_resident.widgetBehavior;

test "the TCP archive installs its complete profile package atomically" {
    const owned_loop = try newLoop(0x39);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var duplicate_tcp: ?*ctcp.GlowcapTcpNetlayer = null;
    try expectOk(ctcp.glowcap_tcp_netlayer_new(&default_tcp_config, &duplicate_tcp));
    defer ctcp.glowcap_tcp_netlayer_release(duplicate_tcp);
    var duplicate: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(ctcp.glowcap_tcp_transport_provider(duplicate_tcp, &duplicate));
    try expectOk(harness.addProvider(loop, &duplicate));

    const conflicting_config: ctcp.GlowcapTcpConfig = .{ .stream = .{
        .keepalive_idle_sec = 30,
        .keepalive_interval_sec = 10,
        .keepalive_count = 3,
    }, .profiles = ctcp.GLOWCAP_TCP_PROFILES_ALL };
    var conflicting_tcp: ?*ctcp.GlowcapTcpNetlayer = null;
    try expectOk(ctcp.glowcap_tcp_netlayer_new(&conflicting_config, &conflicting_tcp));
    defer ctcp.glowcap_tcp_netlayer_release(conflicting_tcp);
    var conflicting: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(ctcp.glowcap_tcp_transport_provider(conflicting_tcp, &conflicting));
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        harness.addProvider(loop, &conflicting),
    );

    const plain_listener = try listenReady(loop, "tcp", "127.0.0.1:0");
    var restoration_len: usize = 99;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_restoration_state(
            loop,
            plain_listener,
            null,
            0,
            &restoration_len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), restoration_len);
    const keyed_listener = try listenReady(loop, "keyed-tcp", "127.0.0.1:0");
    try std.testing.expect(keyed_listener != plain_listener);

    const keyed_locator = try readListenerLocator(loop, keyed_listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, keyed_locator);
    try std.testing.expectEqualStrings("keyed-tcp", keyed_locator.transport);
    try std.testing.expect(directAddresses(keyed_locator) != null);

    const advertised = "203.0.113.1:7447";
    try expectOk(try advertiseParts(loop, plain_listener, "tcp", advertised, ""));
    const advertised_locator = try readListenerLocator(loop, plain_listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, advertised_locator);
    try std.testing.expectEqualStrings("tcp", advertised_locator.transport);
    try std.testing.expectEqualStrings(advertised, advertised_locator.designator);
    try std.testing.expect(directAddresses(advertised_locator) == null);
    try expectOk(try advertiseParts(loop, plain_listener, "tcp", advertised, "127.0.0.1:7447"));
    const plain_with_hint = try readListenerLocator(loop, plain_listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, plain_with_hint);
    try std.testing.expectEqualStrings("127.0.0.1:7447", directAddresses(plain_with_hint).?);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        try advertiseParts(loop, plain_listener, "tcp", "not-an-address", ""),
    );

    const wrong_key = @as([glowcap.foundation.crypto.PeerKey.designator_len]u8, @splat('0'));
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        try advertiseParts(loop, keyed_listener, "keyed-tcp", &wrong_key, "203.0.113.2:7448"),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        try advertiseParts(loop, keyed_listener, "keyed-tcp", keyed_locator.designator, ""),
    );
    const keyed_after_refusal = try readListenerLocator(loop, keyed_listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, keyed_after_refusal);
    try std.testing.expectEqualStrings(keyed_locator.designator, keyed_after_refusal.designator);
    try std.testing.expectEqualStrings(directAddresses(keyed_locator).?, directAddresses(keyed_after_refusal).?);

    const keyed_public_address = "203.0.113.2:7448";
    try expectOk(try advertiseParts(loop, keyed_listener, "keyed-tcp", keyed_locator.designator, keyed_public_address));
    const keyed_advertised = try readListenerLocator(loop, keyed_listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, keyed_advertised);
    try std.testing.expectEqualStrings(keyed_locator.designator, keyed_advertised.designator);
    try std.testing.expectEqualStrings(keyed_public_address, directAddresses(keyed_advertised).?);

    var duplicate_listener: u64 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, null, &duplicate_listener),
    );

    try expectOk(cdrv.glowcap_driver_listener_select(loop, plain_listener));
    try expectOk(harness.closeListener(loop, plain_listener));
    var closed_locator: cdrv.GlowcapLocatorView = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_locator(loop, plain_listener, &closed_locator),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_select(loop, plain_listener),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        harness.closeListener(loop, plain_listener),
    );

    const replacement_listener = try listenReady(loop, "tcp", "127.0.0.1:0");
    try std.testing.expect(replacement_listener != plain_listener);
    try expectOk(cdrv.glowcap_driver_listener_select(loop, keyed_listener));
}

test "the relay archive owns clear and sealed rendezvous profiles as one package" {
    const relay_url = "ws://127.0.0.1:1/relay";
    const register_url = "ws://127.0.0.1:1/register";
    const config: crelay.GlowcapRelayConfig = .{
        .relay_url = relay_url.ptr,
        .relay_url_len = relay_url.len,
        .register_url = register_url.ptr,
        .register_url_len = register_url.len,
    };
    var runtime: ?*crelay.GlowcapRelayRuntime = null;
    try expectOk(crelay.glowcap_relay_runtime_new(&config, &runtime));
    defer expectOk(crelay.glowcap_relay_runtime_release(runtime, null, 0, null)) catch unreachable;

    var package: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(crelay.glowcap_relay_transport_provider(runtime, &package));
    try std.testing.expectEqual(@as(usize, 2), package.entry_count);
    const entries = package.entries.?[0..package.entry_count];
    try std.testing.expectEqual(cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED, entries[0].execution_model);
    try std.testing.expectEqual(cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED, entries[1].execution_model);
    try std.testing.expectEqualStrings(
        "keyed-relay",
        entries[0].profile.?.transport_name.?[0..entries[0].profile.?.transport_name_len],
    );
    try std.testing.expectEqualStrings(
        "noise-relay",
        entries[1].profile.?.transport_name.?[0..entries[1].profile.?.transport_name_len],
    );
    try std.testing.expectEqual(cdrv.GLOWCAP_SEALED_CHANNEL_NONE, entries[0].profile.?.sealed_channel);
    try std.testing.expectEqual(cdrv.GLOWCAP_SEALED_CHANNEL_NOISE_XK, entries[1].profile.?.sealed_channel);

    const owned_loop = try newLoop(0x3f);
    defer owned_loop.deinit();
    try expectOk(harness.addProvider(owned_loop.raw, &package));
}

test "keyed-tcp is available at loop construction and retains unauthenticated provenance" {
    const owned_server = try newLoop(0x48);
    defer owned_server.deinit();
    const server = owned_server.raw;

    const listener_id = try listenReady(server, "keyed-tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener_id));
    const locator = try readListenerLocator(server, listener_id);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqual(@as(usize, 64), locator.designator.len);
    const direct = directAddresses(locator) orelse return error.MissingDirectAddresses;
    try std.testing.expect(direct.len != 0);

    const owned_client = try newLoop(0x49);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "keyed-tcp", locator.designator, direct, &ticket));
    try expectStep(cdrv.glowcap_driver_step(client, 0));
    try expectLoopReadable(server);

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while (client_seen.dialed_session == null and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.glowcap_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        try std.testing.expect(!client_seen.dial_failed);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    var client_identity = std.mem.zeroes(cd.GlowcapPartnerIdentity);
    try expectOk(cd.glowcap_host_session_partner_identity(client_seen.dialed_session, &client_identity));
    try std.testing.expectEqual(cd.GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED, client_identity.provenance);
    var server_identity = std.mem.zeroes(cd.GlowcapPartnerIdentity);
    try expectOk(cd.glowcap_host_session_partner_identity(server_seen.accepted_session, &server_identity));
    try std.testing.expectEqual(cd.GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED, server_identity.provenance);
    try expectOk(cdrv.glowcap_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.glowcap_driver_session_release(server, server_seen.accepted_session));
}

test "noise-tcp is available at loop construction with a dialable locator and authenticated sessions" {
    const owned_server = try newLoop(0x46);
    defer owned_server.deinit();
    const server = owned_server.raw;

    const listener_id = try listenReady(server, "noise-tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener_id));
    try expectOk(cd.glowcap_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));

    const locator = try readListenerLocator(server, listener_id);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqual(@as(usize, 64), locator.designator.len);
    const direct = directAddresses(locator) orelse return error.MissingDirectAddresses;
    try std.testing.expect(direct.len != 0);

    const owned_client = try newLoop(0x47);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "noise-tcp", locator.designator, direct, &ticket));
    try expectStep(cdrv.glowcap_driver_step(client, 0));
    try expectLoopReadable(server);

    var client_seen = Drained{};
    var server_seen = Drained{};
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.glowcap_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and
            server_seen.accepted_session != null and
            fetch_vow == 0)
        {
            var client_identity = std.mem.zeroes(cd.GlowcapPartnerIdentity);
            try expectOk(cd.glowcap_host_session_partner_identity(client_seen.dialed_session, &client_identity));
            try std.testing.expectEqual(
                cd.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                client_identity.provenance,
            );
            var server_identity = std.mem.zeroes(cd.GlowcapPartnerIdentity);
            try expectOk(cd.glowcap_host_session_partner_identity(server_seen.accepted_session, &server_identity));
            try std.testing.expectEqual(
                cd.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                server_identity.provenance,
            );
            try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
            try std.testing.expectEqual(ticket, client_seen.dialed_operation_id);
            try expectOk(cd.glowcap_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        try std.testing.expect(!client_seen.dial_failed);
        try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
    try expectOk(cdrv.glowcap_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.glowcap_driver_session_release(server, server_seen.accepted_session));
}

const Table = cdrv.GlowcapMultiplexedTransport;
var relay_close: @FieldType(Table, "conn_close") = null;

/// What an armed `failingClose` reports from the completing close.
const CloseReport = enum { healthy, bare, detailed };
var armed_close: CloseReport = .healthy;
var failing_client: ?*anyopaque = null;
var client_close_failed = false;

/// The relay's own `conn_close`, then, while armed, a failed completing
/// return: a primary alone, or one with carrier detail and a consequence.
fn failingClose(ctx: ?*anyopaque, conn: u64, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
    const code = relay_close.?(ctx, conn, out);
    if (armed_close == .healthy or code != c.GLOWCAP_OK) return code;
    if (failing_client) |client| {
        if (ctx != client) return code;
        client_close_failed = true;
    }
    const failure = out.?;
    const secondary = "CloseSecondary";
    _ = providerFailure(failure, c.GLOWCAP_ERR_IO, "CloseCleanupFailed");
    if (armed_close == .bare) return c.GLOWCAP_ERR_IO;
    failure.carrier_phase = close_carrier.phase;
    failure.carrier_detail_flags = close_carrier.detail_flags;
    failure.carrier_verification_flags = close_carrier.verification_flags;
    failure.carrier_peer_alert = close_carrier.peer_alert;
    failure.carrier_engine_code = close_carrier.engine_code;
    failure.secondary_result = c.GLOWCAP_ERR_INTERNAL;
    failure.secondary_name = secondary.ptr;
    failure.secondary_name_len = secondary.len;
    failure.secondary_count = 1;
    return c.GLOWCAP_ERR_IO;
}

const close_carrier: harness.Carrier = .{
    .phase = cdrv.GLOWCAP_CARRIER_PHASE_SHUTDOWN,
    .detail_flags = cdrv.GLOWCAP_CARRIER_DETAIL_PEER_ALERT | cdrv.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE,
    .verification_flags = 0x08,
    .peer_alert = 80,
    .engine_code = -0x2701,
};

/// Point every profile of the relay package at `table`, a copy of the
/// package's one connection table. The profiles share one resident, so the
/// copy keeps that single identity while the caller replaces callbacks.
fn copyRelayTable(provider: *cdrv.GlowcapTransportProvider, table: *Table, entries: *[4]cdrv.GlowcapTransportProviderEntry) !void {
    try std.testing.expect(provider.entry_count <= entries.len);
    const original: *const Table = @ptrCast(@alignCast(provider.entries.?[0].implementation.?));
    table.* = original.*;
    relay_close = original.conn_close;
    for (provider.entries.?[0..provider.entry_count], 0..) |entry, i| {
        try std.testing.expectEqual(cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED, entry.execution_model);
        try std.testing.expectEqual(original, @as(*const Table, @ptrCast(@alignCast(entry.implementation.?))));
        entries[i] = entry;
        entries[i].implementation = table;
    }
    provider.entries = entries;
}

// Report only a slow phase. Keep this alive through deferred runtime cleanup,
// where a blocked join would otherwise erase the last useful observation.
const RelayPhase = enum(u8) { registration, dial, client_step, client_events, server_step, server_events, serve, fetch, client_release, client_close, remote_close, server_release, runtime_cleanup, bridge_join };

fn reportRelayStall(io: std.Io, phase: *const std.atomic.Value(RelayPhase), rounds: *const std.atomic.Value(usize)) std.Io.Cancelable!void {
    while (true) {
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5_000), .real);
        std.debug.print("noise-relay C driver: still in {s}, round {d}\n", .{ @tagName(phase.load(.acquire)), rounds.load(.acquire) });
    }
}

const CloseHow = union(enum) { release, detached_failure, close: CloseReport };

/// Dial an authenticated noise-relay session, serve a fetch, then end it from
/// the client by releasing its handle or closing the session. The close
/// verb's connection close, on both ends, reports its `CloseReport`.
fn relayDialAndClose(how: CloseHow) !void {
    defer armed_close = .healthy;
    defer failing_client = null;
    client_close_failed = false;
    if (!(@import("builtin").target.os.tag == .linux or @import("builtin").target.os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var phase = std.atomic.Value(RelayPhase).init(.registration);
    var progress_rounds = std.atomic.Value(usize).init(0);
    var progress = try io.concurrent(reportRelayStall, .{ io, &phase, &progress_rounds });
    var progress_stopped = false;
    errdefer if (!progress_stopped) wait.joinedUnwinding("progress", progress.cancel(io));
    const relay_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var relay_server = try std.Io.net.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.mem.print(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.mem.print(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});
    var relay = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &relay_server, allocator });
    var relay_joined = false;
    errdefer if (!relay_joined) wait.joinedUnwinding("relay", relay.cancel(io));

    {
        const owned_server = try newLoop(0x5a);
        defer owned_server.deinit();
        const server_relay_config: crelay.GlowcapRelayConfig = .{
            .relay_url = relay_url.ptr,
            .relay_url_len = relay_url.len,
            .register_url = register_url.ptr,
            .register_url_len = register_url.len,
        };
        var server_relay_runtime: ?*crelay.GlowcapRelayRuntime = null;
        try expectOk(crelay.glowcap_relay_runtime_new(&server_relay_config, &server_relay_runtime));
        defer expectOk(crelay.glowcap_relay_runtime_release(server_relay_runtime, null, 0, null)) catch unreachable;
        var server_provider: cdrv.GlowcapTransportProvider = undefined;
        try expectOk(crelay.glowcap_relay_transport_provider(server_relay_runtime, &server_provider));
        var server_entries: [4]cdrv.GlowcapTransportProviderEntry = undefined;
        var server_table: Table = undefined;
        try copyRelayTable(&server_provider, &server_table, &server_entries);
        server_table.conn_take_failure = injectedMultiplexedConnectionFailure;
        server_table.conn_close = failingClose;
        try expectOk(harness.addProvider(owned_server.raw, &server_provider));
        const listener_id = try listenReady(owned_server.raw, "noise-relay", "");
        try expectOk(cdrv.glowcap_driver_listener_select(owned_server.raw, listener_id));
        try expectOk(cd.glowcap_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));
        const locator = try readListenerLocator(owned_server.raw, listener_id);
        defer glowcap.ocapn.model.freePeerLocator(allocator, locator);
        try std.testing.expectEqualStrings("noise-relay", locator.transport);
        try std.testing.expectEqual(@as(usize, glowcap.foundation.crypto.PeerKey.designator_len), locator.designator.len);

        var owned_client = try newLoop(0x5b);
        defer owned_client.deinit();
        // The provider default is unreachable. The complete
        // listener locator must carry the actual rendezvous route into the
        // multiplexed provider; reconstructing only transport + designator would
        // fail this dial.
        const unavailable_default = "ws://127.0.0.1:1/relay";
        const client_relay_config: crelay.GlowcapRelayConfig = .{
            .relay_url = unavailable_default.ptr,
            .relay_url_len = unavailable_default.len,
        };
        var client_relay_runtime: ?*crelay.GlowcapRelayRuntime = null;
        try expectOk(crelay.glowcap_relay_runtime_new(&client_relay_config, &client_relay_runtime));
        defer expectOk(crelay.glowcap_relay_runtime_release(client_relay_runtime, null, 0, null)) catch unreachable;
        var client_provider: cdrv.GlowcapTransportProvider = undefined;
        try expectOk(crelay.glowcap_relay_transport_provider(client_relay_runtime, &client_provider));
        var client_entries: [4]cdrv.GlowcapTransportProviderEntry = undefined;
        var client_table: Table = undefined;
        try copyRelayTable(&client_provider, &client_table, &client_entries);
        client_table.conn_close = failingClose;
        try expectOk(harness.addProvider(owned_client.raw, &client_provider));
        var ticket: u64 = 0;
        phase.store(.dial, .release);
        try expectOk(try dialLocator(owned_client.raw, locator, &ticket));

        var client_seen = Drained{};
        var server_seen = Drained{};
        var fetch_vow: u64 = 0;
        var rounds: usize = 0;
        while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
            progress_rounds.store(rounds, .release);
            phase.store(.client_step, .release);
            try expectStep(cdrv.glowcap_driver_step(owned_client.raw, 5));
            phase.store(.client_events, .release);
            try drainEvents(owned_client.raw, &client_seen);
            phase.store(.server_step, .release);
            try expectStep(cdrv.glowcap_driver_step(owned_server.raw, 5));
            phase.store(.server_events, .release);
            try drainEvents(owned_server.raw, &server_seen);
            if (client_seen.dialed_session != null and
                server_seen.accepted_session != null and
                fetch_vow == 0)
            {
                var client_identity = std.mem.zeroes(cd.GlowcapPartnerIdentity);
                try expectOk(cd.glowcap_host_session_partner_identity(client_seen.dialed_session, &client_identity));
                try std.testing.expectEqual(
                    cd.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                    client_identity.provenance,
                );
                var server_identity = std.mem.zeroes(cd.GlowcapPartnerIdentity);
                try expectOk(cd.glowcap_host_session_partner_identity(server_seen.accepted_session, &server_identity));
                try std.testing.expectEqual(
                    cd.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                    server_identity.provenance,
                );
                phase.store(.serve, .release);
                try serveBoth(owned_client.raw, client_seen.dialed_session, owned_server.raw, server_seen.accepted_session);
                phase.store(.fetch, .release);
                try expectOk(cd.glowcap_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
            }
            try std.testing.expect(!client_seen.dial_failed);
            try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
        }
        try std.testing.expect(client_seen.dialed_session != null);
        try std.testing.expect(server_seen.accepted_session != null);
        try std.testing.expect(fetch_vow != 0);
        try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
        // The client has no earlier failure, so a failed close report is its
        // primary. The server's receive failure is earlier, so it stays the
        // primary and a failed close report is a consequence.
        switch (how) {
            .release => {
                phase.store(.client_release, .release);
                try expectOk(cdrv.glowcap_driver_session_release(owned_client.raw, client_seen.dialed_session));
            },
            .detached_failure => {
                failing_client = client_table.ctx;
                try expectOk(cdrv.glowcap_driver_session_close(owned_client.raw, client_seen.dialed_session, &close_cancel));
                try expectOk(cdrv.glowcap_driver_session_release(owned_client.raw, client_seen.dialed_session));
                armed_close = .detailed;
            },
            .close => |report| {
                phase.store(.client_close, .release);
                armed_close = report;
                try expectOk(cdrv.glowcap_driver_session_close(owned_client.raw, client_seen.dialed_session, &close_cancel));
            },
        }
        phase.store(.remote_close, .release);
        rounds = 0;
        while ((!server_seen.closed or (how == .close and !client_seen.closed) or (how == .detached_failure and !client_close_failed)) and rounds < 2_000) : (rounds += 1) {
            if (how != .release) {
                try expectStep(cdrv.glowcap_driver_step(owned_client.raw, 5));
                try drainEvents(owned_client.raw, &client_seen);
            }
            try expectStep(cdrv.glowcap_driver_step(owned_server.raw, 5));
            try drainEvents(owned_server.raw, &server_seen);
        }
        if (how == .close) {
            try std.testing.expect(client_seen.closed);
            switch (how.close) {
                .healthy => {
                    try std.testing.expectEqual(c.GLOWCAP_OK, client_seen.closed_result);
                    try std.testing.expectEqual(@as(usize, 0), client_seen.closed_message_len);
                    try std.testing.expectEqual(@as(u32, 0), client_seen.closed_secondary_count);
                    try std.testing.expectEqual(harness.Carrier{}, client_seen.closed_carrier);
                },
                // A failure that named no phase reports none.
                .bare => {
                    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, client_seen.closed_result);
                    try std.testing.expectEqualStrings(
                        "CloseCleanupFailed",
                        client_seen.closed_message[0..client_seen.closed_message_len],
                    );
                    try std.testing.expectEqual(@as(u32, 0), client_seen.closed_secondary_count);
                    try std.testing.expectEqual(harness.Carrier{}, client_seen.closed_carrier);
                },
                .detailed => {
                    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, client_seen.closed_result);
                    try std.testing.expectEqualStrings(
                        "CloseCleanupFailed",
                        client_seen.closed_message[0..client_seen.closed_message_len],
                    );
                    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, client_seen.closed_secondary_result);
                    try std.testing.expectEqual(@as(u32, 1), client_seen.closed_secondary_count);
                    try std.testing.expectEqual(close_carrier, client_seen.closed_carrier);
                },
            }
            try expectOk(cdrv.glowcap_driver_session_release(owned_client.raw, client_seen.dialed_session));
        }
        try std.testing.expect(server_seen.closed);
        try std.testing.expectEqual(c.GLOWCAP_ERR_IO, server_seen.closed_result);
        try std.testing.expectEqualStrings(
            "InjectedMultiplexedReadFailure",
            server_seen.closed_message[0..server_seen.closed_message_len],
        );
        try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, server_seen.closed_secondary_result);
        // The injected failure's two consequences, then a failed close adds
        // its primary and any consequence of its own.
        try std.testing.expectEqual(@as(u32, switch (how) {
            .release, .detached_failure => 2,
            .close => |report| switch (report) {
                .healthy => 2,
                .bare => 3,
                .detailed => 4,
            },
        }), server_seen.closed_secondary_count);
        try std.testing.expectEqualStrings(
            "InjectedMultiplexedCleanupFailure",
            server_seen.closed_secondary_message[0..server_seen.closed_secondary_message_len],
        );
        try std.testing.expectEqual(harness.Carrier{
            .phase = cdrv.GLOWCAP_CARRIER_PHASE_RECEIVE,
            .detail_flags = cdrv.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE,
            .engine_code = residents.injected_receive_engine_code,
        }, server_seen.closed_carrier);
        try expectStep(cdrv.glowcap_driver_step(owned_server.raw, 0));
        try drainEvents(owned_server.raw, &server_seen);
        try std.testing.expectEqual(@as(usize, 1), server_seen.closed_count);
        phase.store(.server_release, .release);
        try expectOk(cdrv.glowcap_driver_session_release(owned_server.raw, server_seen.accepted_session));
        var host_id: u64 = 0;
        try expectOk(cd.glowcap_host_diagnostic_id(owned_client.host, &host_id));
        var failure = cdrv.GlowcapDriverFailure.init();
        try expectOk(owned_client.release(&failure));
        if (how == .detached_failure) {
            try std.testing.expect(client_close_failed);
            try std.testing.expect(!client_seen.closed);
            try @import("context_failures.zig").expectOne(owned_client.context, .{
                .scope = c.GLOWCAP_FAILURE_SCOPE_HOST,
                .id = host_id,
                .operation = "driver",
                .primary = c.GLOWCAP_ERR_IO,
                .name = "CloseCleanupFailed",
                .secondary = c.GLOWCAP_ERR_INTERNAL,
                .secondary_name = "CloseSecondary",
                .secondary_count = 1,
            });
        } else try @import("context_failures.zig").expectEmpty(owned_client.context);
        phase.store(.runtime_cleanup, .release);
    }
    phase.store(.bridge_join, .release);
    relay_joined = true;
    try relay.await(io);

    // The reporter loops until cancelled, so cancelling ends it with `Canceled`.
    progress_stopped = true;
    try std.testing.expectError(error.Canceled, progress.cancel(io));
}

test "the relay provider registers and dials an authenticated noise-relay session through the C driver" {
    try relayDialAndClose(.release);
}

test "closing a noise-relay session from the client reports a clean close" {
    try relayDialAndClose(.{ .close = .healthy });
}

test "a failed noise-relay close that names no carrier phase reports none" {
    try relayDialAndClose(.{ .close = .bare });
}

test "a failed noise-relay close reports its carrier detail through the C driver" {
    try relayDialAndClose(.{ .close = .detailed });
}

test "a noise-relay close completing after session release reaches its original Host Context" {
    try relayDialAndClose(.detached_failure);
}
