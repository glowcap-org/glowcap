//! The shipped transport archives through the C driver: the TCP package
//! installs atomically with keyed-tcp and noise-tcp profiles, and the relay
//! archive owns clear and sealed rendezvous as one package, dialing an
//! authenticated noise-relay session.

const std = @import("std");

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
const frame_cap = harness.frame_cap;
const default_tcp_config = harness.default_tcp_config;
const driver_options_1s = harness.driver_options_1s;
const driver_options_10s = harness.driver_options_10s;
const driver_options_cap1 = harness.driver_options_cap1;
const close_cancel = harness.close_cancel;
const providerFailure = harness.providerFailure;
const drained = harness.drained;
const expectOk = harness.expectOk;
const expectStep = harness.expectStep;
const retainStaticProvider = harness.retainStaticProvider;
const releaseStaticProvider = harness.releaseStaticProvider;
const sameStaticProvider = harness.sameStaticProvider;
const providerProfile = harness.providerProfile;
const addMultiplexedProviderWithProfile = harness.addMultiplexedProviderWithProfile;
const addMultiplexedProvider = harness.addMultiplexedProvider;
const addStreamProvider = harness.addStreamProvider;
const openAccepted = harness.openAccepted;
const readListenerLocator = harness.readListenerLocator;
const expectLoopReadable = harness.expectLoopReadable;
const directAddresses = harness.directAddresses;
const callWithLocator = harness.callWithLocator;
const dialParts = harness.dialParts;
const dialLocator = harness.dialLocator;
const advertiseParts = harness.advertiseParts;
const hostSeed = harness.hostSeed;
const TestLoop = harness.TestLoop;
const installTcp = harness.installTcp;
const installRelay = harness.installRelay;
const newEmptyLoop = harness.newEmptyLoop;
const newLoop = harness.newLoop;
const newByteFedHost = harness.newByteFedHost;
const Drained = harness.Drained;
const serveBoth = harness.serveBoth;
const drainEvents = harness.drainEvents;
const awaitListenerReady = harness.awaitListenerReady;
const listenReady = harness.listenReady;
const noStreamConnectionFailure = residents.noStreamConnectionFailure;
const noMultiplexedConnectionFailure = residents.noMultiplexedConnectionFailure;
const injectedStreamConnectionFailure = residents.injectedStreamConnectionFailure;
const injectedMultiplexedConnectionFailure = residents.injectedMultiplexedConnectionFailure;
const InvalidMultiplexedResident = residents.InvalidMultiplexedResident;
const MalformedImmediateStream = residents.MalformedImmediateStream;
const AsyncFailureResident = residents.AsyncFailureResident;
const TypedResident = typed_resident.TypedResident;
const typedProvider = typed_resident.typedProvider;
const widgetBehavior = typed_resident.widgetBehavior;
const ReentrantSessionRelease = typed_resident.ReentrantSessionRelease;
const CallbackRetirement = typed_resident.CallbackRetirement;
const callbackRetirementBehavior = typed_resident.callbackRetirementBehavior;
const reentrantSessionReleaseBehavior = typed_resident.reentrantSessionReleaseBehavior;

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
    } };
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

test "the relay provider registers and dials an authenticated noise-relay session through the C driver" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const relay_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var relay_server = try std.Io.net.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});
    var relay = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &relay_server, allocator });
    defer _ = relay.cancel(io) catch {};

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
        try std.testing.expect(server_provider.entry_count <= 4);
        var server_entries: [4]cdrv.GlowcapTransportProviderEntry = undefined;
        const original_table: *const cdrv.GlowcapMultiplexedTransport = @ptrCast(@alignCast(server_provider.entries.?[0].implementation.?));
        var server_table = original_table.*;
        server_table.conn_take_failure = injectedMultiplexedConnectionFailure;
        for (server_provider.entries.?[0..server_provider.entry_count], 0..) |entry, i| {
            server_entries[i] = entry;
            try std.testing.expectEqual(cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED, entry.execution_model);
            const original: *const cdrv.GlowcapMultiplexedTransport = @ptrCast(@alignCast(entry.implementation.?));
            try std.testing.expectEqual(original_table, original);
            // All profiles in this package share one resident.
            // Preserve that identity while replacing the one callback under
            // test; distinct copied table addresses would falsely describe
            // distinct resident owners to the registry.
            server_entries[i].implementation = &server_table;
        }
        server_provider.entries = &server_entries;
        try expectOk(harness.addProvider(owned_server.raw, &server_provider));
        const listener_id = try listenReady(owned_server.raw, "noise-relay", "");
        try expectOk(cdrv.glowcap_driver_listener_select(owned_server.raw, listener_id));
        try expectOk(cd.glowcap_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));
        const locator = try readListenerLocator(owned_server.raw, listener_id);
        defer glowcap.ocapn.model.freePeerLocator(allocator, locator);
        try std.testing.expectEqualStrings("noise-relay", locator.transport);
        try std.testing.expectEqual(@as(usize, glowcap.foundation.crypto.PeerKey.designator_len), locator.designator.len);

        const owned_client = try newLoop(0x5b);
        defer owned_client.deinit();
        // The provider default is unreachable. The complete
        // listener locator must carry the actual rendezvous route into the
        // multiplexed provider; reconstructing only transport + designator would
        // fail this dial.
        const unavailable_default = "ws://127.0.0.1:1/relay";
        try installRelay(owned_client.raw, unavailable_default, "");
        var ticket: u64 = 0;
        try expectOk(try dialLocator(owned_client.raw, locator, &ticket));

        var client_seen = Drained{};
        var server_seen = Drained{};
        var fetch_vow: u64 = 0;
        var rounds: usize = 0;
        while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
            try expectStep(cdrv.glowcap_driver_step(owned_client.raw, 5));
            try drainEvents(owned_client.raw, &client_seen);
            try expectStep(cdrv.glowcap_driver_step(owned_server.raw, 5));
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
                try serveBoth(owned_client.raw, client_seen.dialed_session, owned_server.raw, server_seen.accepted_session);
                try expectOk(cd.glowcap_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
            }
            try std.testing.expect(!client_seen.dial_failed);
            try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
        }
        try std.testing.expect(client_seen.dialed_session != null);
        try std.testing.expect(server_seen.accepted_session != null);
        try std.testing.expect(fetch_vow != 0);
        try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
        try expectOk(cdrv.glowcap_driver_session_release(owned_client.raw, client_seen.dialed_session));
        rounds = 0;
        while (!server_seen.closed and rounds < 2_000) : (rounds += 1) {
            try expectStep(cdrv.glowcap_driver_step(owned_server.raw, 5));
            try drainEvents(owned_server.raw, &server_seen);
        }
        try std.testing.expect(server_seen.closed);
        try std.testing.expectEqual(c.GLOWCAP_ERR_IO, server_seen.closed_result);
        try std.testing.expectEqualStrings(
            "InjectedMultiplexedReadFailure",
            server_seen.closed_message[0..server_seen.closed_message_len],
        );
        try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, server_seen.closed_secondary_result);
        try std.testing.expectEqual(@as(u32, 2), server_seen.closed_secondary_count);
        try std.testing.expectEqualStrings(
            "InjectedMultiplexedCleanupFailure",
            server_seen.closed_secondary_message[0..server_seen.closed_secondary_message_len],
        );
        try expectStep(cdrv.glowcap_driver_step(owned_server.raw, 0));
        try drainEvents(owned_server.raw, &server_seen);
        try std.testing.expectEqual(@as(usize, 1), server_seen.closed_count);
        try expectOk(cdrv.glowcap_driver_session_release(owned_server.raw, server_seen.accepted_session));
    }
    try relay.await(io);
}
