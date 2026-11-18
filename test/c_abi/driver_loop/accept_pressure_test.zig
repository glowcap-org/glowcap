//! Admission pressure on one accepted connection, seen from the C step: the
//! arrival is retired and the step still answers OK or WOULD_BLOCK, because a
//! step error is a terminal loop. Each run refuses every allocation of the
//! Host's allocator from one index on, while one connection arrives at a
//! listener that already serves a session. After the allocator recovers the
//! listener has not failed, the established session still answers a fetch, and
//! the next dial is accepted.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const ctcp = @import("c_abi_net_transport_tcp");
const glowcap = @import("glowcap");
const CountingHost = @import("../../support/c_abi_counting_alloc.zig").CountingHost;

const harness = @import("harness.zig");
const typed_resident = @import("typed_resident.zig");
const Drained = harness.Drained;
const drainEvents = harness.drainEvents;
const expectLoopReadable = harness.expectLoopReadable;
const expectOk = harness.expectOk;
const expectStep = harness.expectStep;

const max_indexes = 64;

/// How the loop reaches TCP: the packaged provider, or its stream table
/// registered by hand through `addStreamProvider`, as an embedder's own
/// stream provider is.
const Install = enum { packaged, stream_table };

/// The stream table's context is the netlayer, which the loop does not
/// retain: the caller releases `tcp` after the loop.
fn installStreamTable(loop: ?*cdrv.GlowcapDriverLoop, tcp: *?*ctcp.GlowcapTcpNetlayer) !void {
    try expectOk(ctcp.glowcap_tcp_netlayer_new(&harness.default_tcp_config, tcp));
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(ctcp.glowcap_tcp_transport_provider(tcp.*, &provider));
    for (provider.entries.?[0..provider.entry_count]) |entry| {
        if (entry.execution_model != cdrv.GLOWCAP_TRANSPORT_EXEC_STREAM) continue;
        if (!std.mem.eql(u8, entry.profile.?.transport_name.?[0..entry.profile.?.transport_name_len], "tcp")) continue;
        const table: *const cdrv.GlowcapStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
        try expectOk(harness.addStreamProvider(loop, table, "tcp"));
        return;
    }
    return error.NoTcpStreamEntry;
}

/// Fetch again over the established pair and wait for the answer.
fn expectFetch(pair: *harness.FetchedPair) !void {
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(pair.client_seen.dialed_session, "widget", 6, &vow));
    try pair.settle(vow);
}

/// Whether the runtime closed this socket: it turns readable within a second,
/// and reads end of stream when closed or the runtime's hello when admitted.
fn peerClosed(fd: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 1_000));
    var byte: [1]u8 = undefined;
    return try std.posix.read(fd, &byte) == 0;
}

/// What became of the arrival. A refusal can also land beside the arrival,
/// on allocations the step makes for itself, and the arrival is admitted then.
const Outcome = enum { retired, admitted_under_pressure, admitted };

/// One run: refuse the Host's allocations from `offset` on while a silent
/// connection arrives, then check what survived.
fn run(offset: usize, install: Install) !Outcome {
    var counting = CountingHost{};
    const outcome = try runOn(&counting, offset, install);
    // Every byte the Host's allocator served came back, retired arrival included.
    try std.testing.expect(counting.balanced());
    return outcome;
}

fn runOn(counting: *CountingHost, offset: usize, install: Install) !Outcome {
    const spec = counting.spec();
    var stream_netlayer: ?*ctcp.GlowcapTcpNetlayer = null;
    defer ctcp.glowcap_tcp_netlayer_release(stream_netlayer);
    var server = try harness.newByteFedHost(0x41, &spec);
    {
        errdefer server.deinit();
        try expectOk(cd.glowcap_host_publish(server.host, "widget", 6, typed_resident.widgetBehavior, null, null));
        try expectOk(cdrv.glowcap_driver_take_host(server.host, &harness.driver_options_10s, &server.raw));
        switch (install) {
            .packaged => try harness.installTcp(server.raw),
            .stream_table => try installStreamTable(server.raw, &stream_netlayer),
        }
    }

    // An established session on the listener, answering a fetch.
    var pair = try harness.connectAndFetch(server, 0x42, "widget");
    defer pair.deinit();
    const locator = try harness.readListenerLocator(server.raw, pair.listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const address = try glowcap.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, threaded.io(), .{ .mode = .stream });
    defer silent.close(threaded.io());

    try expectLoopReadable(server.raw);
    counting.allocations_before_failure = offset;
    const step = cdrv.glowcap_driver_step(server.raw, 0);
    counting.allocations_before_failure = null;
    // Pressure never reaches the binding as a terminal code.
    try expectStep(step);
    var seen = Drained{};
    try drainEvents(server.raw, &seen);
    try std.testing.expect(!seen.listener_failed);
    try std.testing.expect(!seen.accepted);

    const closed = try peerClosed(silent.socket.handle);
    if (closed) {
        // The arrival was retired: its socket is closed, not parked.
        try std.testing.expect(counting.refused != 0);
        // The established session still serves.
        try expectFetch(&pair);
        // The listener takes the next arrival.
        const client = try harness.newLoop(0x43);
        defer client.deinit();
        var operation: u64 = 0;
        try expectOk(try harness.dialParts(client.raw, "tcp", locator.designator, "", &operation));
        var client_seen = Drained{};
        var server_seen = Drained{};
        var rounds: usize = 0;
        while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
            try expectStep(cdrv.glowcap_driver_step(client.raw, 5));
            try drainEvents(client.raw, &client_seen);
            try expectStep(cdrv.glowcap_driver_step(server.raw, 5));
            try drainEvents(server.raw, &server_seen);
        }
        try std.testing.expect(client_seen.dialed_session != null);
        try std.testing.expectEqual(pair.listener, server_seen.accepted_listener);
        try std.testing.expect(!server_seen.listener_failed);
        try expectOk(cdrv.glowcap_driver_session_release(client.raw, client_seen.dialed_session));
        try expectOk(cdrv.glowcap_driver_session_release(server.raw, server_seen.accepted_session));
    }
    try pair.releaseSessions();
    if (closed) return .retired;
    return if (counting.refused != 0) .admitted_under_pressure else .admitted;
}

fn sweep(install: Install) !void {
    var retired: usize = 0;
    var reached_admitted = false;
    for (0..max_indexes) |offset| {
        switch (try run(offset, install)) {
            .retired => retired += 1,
            .admitted_under_pressure => {},
            .admitted => {
                reached_admitted = true;
                break;
            },
        }
    }
    try std.testing.expect(reached_admitted);
    try std.testing.expect(retired >= 1);
}

test "admission pressure on one arrival leaves the C step OK and the listener serving" {
    try sweep(.packaged);
}

test "admission pressure through an embedder's stream provider leaves the same listener serving" {
    try sweep(.stream_table);
}
