//! The headline loopback (ADR-0112): two stepping loops carry listen, dial,
//! fetch, settle, and hangup over real TCP; one thread can step both ends of
//! a nonblocking handshake; session handles outlive driver close until
//! explicit release; callbacks may not re-enter a session release.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const crelay = @import("c_abi_net_transport_relay");
const ctcp = @import("c_abi_net_transport_tcp");
const pancake = @import("pancake");
const c_args = @import("../../support/c_abi_args.zig");
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

/// The server embedder's whole life, shared with the test thread through
/// atomics and one write-once designator buffer.
const ServerShared = struct {
    designator_buf: [128]u8 = undefined,
    designator_len: usize = 0,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn serverMain(shared: *ServerShared) void {
    serverBody(shared) catch shared.failed.store(true, .release);
}

fn serverBody(shared: *ServerShared) !void {
    const owned_loop = try newLoop(0x11);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    const listener_id = try listenReady(loop, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(loop, listener_id));
    // A duplicate transport is refused because the Host has one advertised
    // locator per transport.
    var duplicate_listener: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, null, &duplicate_listener),
    );
    var readiness: i32 = -1;
    try expectOk(cdrv.pancake_driver_readiness_fd(loop, &readiness));
    try std.testing.expect(readiness >= 0);

    try expectOk(cd.pancake_host_publish(owned_loop.host, "widget", 6, widgetBehavior, null, null));

    const locator = try readListenerLocator(loop, listener_id);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    shared.designator_len = locator.designator.len;
    @memcpy(shared.designator_buf[0..shared.designator_len], locator.designator);
    shared.ready.store(true, .release);

    var seen = Drained{};
    var served_accept = false;
    while (!shared.stop.load(.acquire)) {
        try expectStep(cdrv.pancake_driver_step(loop, 20));
        try drainEvents(loop, &seen);
        if (seen.accepted) shared.accepted.store(true, .release);
        // An accepted session's inbound is held until the embedder announces
        // its setup is done; without this the client's pipelined fetch below
        // would wait forever.
        if (seen.accepted_session != null and !served_accept) {
            served_accept = true;
            try expectOk(cdrv.pancake_driver_session_serve(loop, seen.accepted_session));
        }
        if (seen.closed) {
            try std.testing.expectEqual(c.PANCAKE_OK, seen.closed_result);
            try std.testing.expectEqual(@as(usize, 0), seen.closed_message_len);
            shared.closed.store(true, .release);
        }
    }

    // Drained queues report WOULD_BLOCK, so an embedder's drain loop ends.
    var event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cdrv.pancake_driver_next_event(loop, &event));
}

test "two stepping loops carry listen, dial, fetch, settle, and hangup over loopback TCP (ADR-0112)" {
    var shared = ServerShared{};
    const server_thread = try std.Thread.spawn(.{}, serverMain, .{&shared});
    var joined = false;
    defer if (!joined) {
        shared.stop.store(true, .release);
        server_thread.join();
    };

    var spins: usize = 0;
    while (!shared.ready.load(.acquire) and !shared.failed.load(.acquire) and spins < 1_000_000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(shared.ready.load(.acquire));
    const designator = shared.designator_buf[0..shared.designator_len];

    const owned_client = try newLoop(0x22);
    defer owned_client.deinit();
    const client = owned_client.raw;

    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", designator, "", &ticket));

    var client_seen = Drained{};
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    var held_rounds: usize = 0;
    var client_served = false;
    while (client_seen.settle_ticket == 0 and rounds < 2000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        if (client_seen.dialed_session != null and fetch_vow == 0) {
            try std.testing.expectEqual(ticket, client_seen.dialed_operation_id);
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        // The settle answers over this session's inbound, which is held until
        // the embedder serves: a stretch of steps first, so a settle arriving
        // early would fail here and expose a hold that stopped holding.
        if (fetch_vow != 0 and !client_served) {
            held_rounds += 1;
            try std.testing.expectEqual(@as(u64, 0), client_seen.settle_ticket);
            if (held_rounds >= 20) {
                client_served = true;
                try expectOk(cdrv.pancake_driver_session_serve(client, client_seen.dialed_session));
            }
        }
        try std.testing.expect(!client_seen.dial_failed);
        try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
    }

    // The dial opened, and the fetch's unobserved settle arrived as a
    // COMPLETION event carrying the fetch's own vow id.
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);

    // Hang up from the client; the server's stepping thread observes the EOF
    // and events the closure without any blocking verb running.
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    var waited: usize = 0;
    while (!shared.closed.load(.acquire) and !shared.failed.load(.acquire) and waited < 2000) : (waited += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
    }

    shared.stop.store(true, .release);
    server_thread.join();
    joined = true;
    try std.testing.expect(!shared.failed.load(.acquire));
    try std.testing.expect(shared.accepted.load(.acquire));
    try std.testing.expect(shared.closed.load(.acquire));

    // The client's queue is drained too, so the borrow contract's "next call
    // frees the last event" leaves nothing behind at release.
    var event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cdrv.pancake_driver_next_event(client, &event));
}

test "two loops stepped by one thread dial each other: the nonblocking handshake advances across steps (ADR-0112)" {
    const owned_server = try newLoop(0x44);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener_id = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener_id));
    try expectOk(cd.pancake_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));
    const locator = try readListenerLocator(server, listener_id);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    const designator = locator.designator;

    // A blocking dial could never complete here: the exporter's loop steps on
    // this same thread, so the handshake must advance across alternating
    // steps or time out.
    const owned_client = try newLoop(0x45);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and
            server_seen.accepted_session != null and
            fetch_vow == 0)
        {
            // Opaque session handles are scoped to the loop that minted them.
            // The peer ids happen to match in this two-loop setup, so checking
            // ownership after a wire lookup would close the server's session.
            try std.testing.expectEqual(
                c.PANCAKE_ERR_INVALID_ARGUMENT,
                cdrv.pancake_driver_session_release(server, client_seen.dialed_session),
            );
            // The serve verb is scoped the same way release is.
            try std.testing.expectEqual(
                c.PANCAKE_ERR_INVALID_ARGUMENT,
                cdrv.pancake_driver_session_serve(server, client_seen.dialed_session),
            );
            try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
            try std.testing.expectEqual(ticket, client_seen.dialed_operation_id);
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        try std.testing.expect(!client_seen.dial_failed);
        try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted);
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));

    // EOF commits one SESSION_CLOSED event. While it is pending, another step
    // reports backpressure without advancing more work. Releasing the session
    // invalidates the event in O(1); the drain skips it without touching the
    // freed shell.
    try expectLoopReadable(server);
    try expectOk(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
    var stale_event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        cdrv.pancake_driver_next_event(server, &stale_event),
    );
}

test "stream provider failure chain reaches SESSION_CLOSED exactly" {
    const owned_server = try newEmptyLoop(0x74);
    defer owned_server.deinit();
    const server = owned_server.raw;

    var tcp_handle: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp_handle));
    defer ctcp.pancake_tcp_netlayer_release(tcp_handle);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp_handle, &provider));
    try std.testing.expect(provider.entry_count <= 4);
    var entries: [4]cdrv.PancakeTransportProviderEntry = undefined;
    var tables: [4]cdrv.PancakeStreamTransport = undefined;
    for (provider.entries.?[0..provider.entry_count], 0..) |entry, i| {
        entries[i] = entry;
        try std.testing.expectEqual(cdrv.PANCAKE_TRANSPORT_EXEC_STREAM, entry.execution_model);
        const original: *const cdrv.PancakeStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
        tables[i] = original.*;
        tables[i].conn_take_failure = injectedStreamConnectionFailure;
        entries[i].implementation = &tables[i];
    }
    provider.entries = &entries;
    try expectOk(harness.addProvider(server, &provider));

    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x75);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var operation: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &operation));
    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or !server_seen.accepted) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));

    rounds = 0;
    while (!server_seen.closed and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(server_seen.closed);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, server_seen.closed_result);
    try std.testing.expectEqualStrings(
        "InjectedStreamReadFailure",
        server_seen.closed_message[0..server_seen.closed_message_len],
    );
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, server_seen.closed_secondary_result);
    try std.testing.expectEqual(@as(u32, 2), server_seen.closed_secondary_count);
    try std.testing.expectEqualStrings(
        "InjectedStreamCleanupFailure",
        server_seen.closed_secondary_message[0..server_seen.closed_secondary_message_len],
    );
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try drainEvents(server, &server_seen);
    try std.testing.expectEqual(@as(usize, 1), server_seen.closed_count);
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "loop-owned session release refuses callback reentry before dropping the wire" {
    const owned_server = try newLoop(0x5f);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var release = ReentrantSessionRelease{ .loop = server, .listener = listener };
    try expectOk(cd.pancake_host_publish(
        owned_server.host,
        "release-probe",
        "release-probe".len,
        reentrantSessionReleaseBehavior,
        &release,
        null,
    ));

    const owned_client = try newLoop(0x60);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var operation: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &operation));

    var client_seen = Drained{};
    var server_seen = Drained{};
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and server_seen.accepted_session != null) break;
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
    release.session = server_seen.accepted_session;

    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(
        client_seen.dialed_session,
        "release-probe",
        "release-probe".len,
        &fetch_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == fetch_vow) break;
    }
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
    try std.testing.expect(client_seen.settled_reference.id != 0);

    client_seen.settle_ticket = 0;
    var call_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(
        client_seen.dialed_session,
        &client_seen.settled_reference,
        "probe",
        "probe".len,
        null,
        0,
        &call_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == call_vow) break;
    }

    try std.testing.expect(release.ran);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, release.result);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, release.readiness_result);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, release.restoration_result);
    try std.testing.expectEqual(call_vow, client_seen.settle_ticket);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "driver retirement requested in a behavior defers listener effects until callback unwind" {
    const owned_server = try newLoop(0x67);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var retirement = CallbackRetirement{ .loop = server };
    try expectOk(cd.pancake_host_publish(
        owned_server.host,
        "retirement-probe",
        "retirement-probe".len,
        callbackRetirementBehavior,
        &retirement,
        null,
    ));

    const owned_client = try newLoop(0x68);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var operation: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &operation));

    var client_seen = Drained{};
    var server_seen = Drained{};
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and server_seen.accepted_session != null) break;
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);

    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(
        client_seen.dialed_session,
        "retirement-probe",
        "retirement-probe".len,
        &fetch_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == fetch_vow) break;
    }
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);

    client_seen.settle_ticket = 0;
    var call_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(
        client_seen.dialed_session,
        &client_seen.settled_reference,
        "retire",
        "retire".len,
        null,
        0,
        &call_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == call_vow) break;
    }

    try std.testing.expect(retirement.ran);
    try std.testing.expectEqual(c.PANCAKE_OK, retirement.result);
    try std.testing.expectEqual(call_vow, client_seen.settle_ticket);
    var stale_locator: cdrv.PancakeLocatorView = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_locator(server, listener, &stale_locator),
    );

    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
}
