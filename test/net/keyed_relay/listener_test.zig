//! The keyed-relay resident and listener lifecycle: retained URL
//! configuration, the complete netlayer contract, a stalled initial
//! registration owned asynchronously, close waking a parked readiness wait,
//! and a stalled replacement recovered without invalidating the locator.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../../support/netlayer.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;
const keyed_relay = net.relay;
const ws_relay = @import("../../support/ws_relay.zig");
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const wait = @import("../../support/wait.zig");

const Io = std.Io;
const ip = std.Io.net;

const admission = @import("../../support/keyed_relay_admission.zig");
const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;

const frame_cap = admission.frame_cap;

const relay_support = @import("harness.zig");
const stubNegotiatingPeer = relay_support.stubNegotiatingPeer;
const startSession = relay_support.startSession;
const serveRegistered = relay_support.serveRegistered;

test "keyed-relay resident owns retained URL configuration" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var url_storage = "ws://127.0.0.1:80/r".*;
    var resident = try keyed_relay.Resident.init(std.testing.allocator, threaded.io(), &url_storage);
    defer _ = resident.deinit();

    @memset(&url_storage, 'x');
    try std.testing.expectEqualStrings("127.0.0.1", resident.configuration().relay_url.host);
    try std.testing.expectEqualStrings("/r", resident.configuration().relay_url.path);
}

test "relay resident profile selects the complete netlayer contract" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var clear = try keyed_relay.Resident.initProfile(
        allocator,
        threaded.io(),
        "ws://127.0.0.1:8000/relay",
        .keyed,
    );
    defer _ = clear.deinit();
    try std.testing.expectEqualStrings(model.transport.keyed_relay, clear.netlayer().transportName());

    var sealed_resident = try keyed_relay.Resident.initProfile(
        allocator,
        threaded.io(),
        "ws://127.0.0.1:8000/relay",
        .noise,
    );
    defer _ = sealed_resident.deinit();
    try std.testing.expectEqualStrings(model.transport.noise_relay, sealed_resident.netlayer().transportName());

    var provider: keyed_relay.Provider = .{};
    try provider.init(allocator, threaded.io(), "ws://127.0.0.1:8000/relay");
    defer _ = provider.deinit();
    const layers = provider.netlayers();
    try std.testing.expectEqual(@as(usize, 2), layers.len);
    try std.testing.expectEqualStrings(model.transport.keyed_relay, layers[0].transportName());
    try std.testing.expectEqualStrings(model.transport.noise_relay, layers[1].transportName());
}

fn holdParkedRegistration(
    io: Io,
    server: *ip.Server,
    pong_seen: *std.atomic.Value(bool),
) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
    try ws_relay.writeServerFrame(&leg, .ping, "ready");
    var payload: [16]u8 = undefined;
    const pong = try ws_relay.readClientFrame(&leg, &payload);
    try std.testing.expectEqual(keyed_relay.Opcode.pong, pong.opcode);
    try std.testing.expectEqualStrings("ready", pong.payload);
    pong_seen.store(true, .release);
    // Listener destruction is abortive and must not perform a network flush.
    // The peer observes EOF rather than a destructor-generated close frame.
    try std.testing.expectError(error.EndOfStream, ws_relay.readClientFrame(&leg, &payload));
}

fn waitOnRegisteredListener(listener: net.netlayer.Listener, out_err: *?anyerror) void {
    _ = listener.waitAcceptable(-1) catch |err| {
        out_err.* = err;
        return;
    };
    out_err.* = error.UnexpectedReadiness;
}

fn serveReadinessRegistrations(
    io: Io,
    server: *ip.Server,
    first_seen: *std.atomic.Value(bool),
    send_data: *std.atomic.Value(bool),
    replacement_seen: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),
) !void {
    var first: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    first.wire();
    defer first.close();
    try confirmRegistration(&first);
    first_seen.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, send_data);
    if (release.load(.acquire)) return;
    try ws_relay.writeServerFrame(&first, .binary, "pending");

    var replacement: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    replacement.wire();
    defer replacement.close();
    try confirmRegistration(&replacement);
    replacement_seen.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, release);
}

fn confirmRegistration(leg: *ws_relay.Leg) !void {
    try ws_relay.serveUpgrade(leg);
    try ws_relay.writeServerFrame(leg, .ping, "ready");
    var payload: [16]u8 = undefined;
    const pong = try ws_relay.readClientFrame(leg, &payload);
    try std.testing.expectEqual(keyed_relay.Opcode.pong, pong.opcode);
    try std.testing.expectEqualStrings("ready", pong.payload);
}

test "keyed-relay listener readiness clears idle hints and retains unclaimed arrivals" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const relay_addr: ip.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{server.socket.address.getPort()});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x6f)));
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    defer std.debug.assert(resident.deinit() == null);
    var first_seen = std.atomic.Value(bool).init(false);
    var send_data = std.atomic.Value(bool).init(false);
    var replacement_seen = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(serveReadinessRegistrations, .{
        io, &server, &first_seen, &send_data, &replacement_seen, &release,
    });
    defer {
        send_data.store(true, .release);
        release.store(true, .release);
        _ = relay.cancel(io) catch {};
    }
    const listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    var listener_live = true;
    defer if (listener_live) {
        _ = listener.close();
    };
    defer {
        send_data.store(true, .release);
        release.store(true, .release);
    }
    var fds = [_]std.posix.pollfd{.{ .fd = listener.readinessFd().?, .events = std.posix.POLL.IN, .revents = 0 }};
    try wait.untilFlag(io, wait.default_deadline_ms, &first_seen);
    try std.testing.expect(!try listener.waitAcceptable(0));
    try std.testing.expectEqual(@as(usize, 0), try net.poll.wait(&fds, 0));

    send_data.store(true, .release);
    try std.testing.expectEqual(@as(usize, 1), try net.poll.wait(&fds, 1000));
    for (0..2) |_| {
        try std.testing.expect(try listener.waitAcceptable(0));
        try std.testing.expectEqual(@as(usize, 1), try net.poll.wait(&fds, 0));
    }
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var conn = try listener.accept(&peer, .{ .read = &read_buf, .write = &write_buf });
    defer conn.deinit();
    try wait.untilFlag(io, wait.default_deadline_ms, &replacement_seen);
    try std.testing.expect(!try listener.waitAcceptable(0));
    // Completion publishes state before its final wake. A late old hint may
    // follow this probe, but cannot invent an acceptable replacement stream.
    try std.testing.expect(!try listener.waitAcceptable(20));
    try std.testing.expectEqual(null, listener.close());
    listener_live = false;
    release.store(true, .release);
    try relay.await(io);
}

fn stallInitialRegistration(
    io: Io,
    server: *ip.Server,
    connected: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),
) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    connected.store(true, .release);
    // Accept TCP but never answer the HTTP upgrade. The listener must already
    // have returned, and its close must cancel this task without cooperation.
    try wait.untilFlag(io, wait.default_deadline_ms, release);
}

fn refuseInitialRegistration(io: Io, server: *ip.Server) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var write_store: [256]u8 = undefined;
    var writer = stream.writer(io, &write_store);
    try writer.interface.writeAll("HTTP/1.1 403 Refused\r\n\r\n");
    try writer.interface.flush();
}

test "keyed-relay listener setup returns the exact registration refusal" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{server.socket.address.getPort()});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x6b)));
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    defer std.debug.assert(resident.deinit() == null);
    var relay = try io.concurrent(refuseInitialRegistration, .{ io, &server });

    var result = switch (resident.netlayer().listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    })) {
        .admitted => |value| value,
        .failed => |failure| return failure.cause,
    };
    defer netlayer_test.deinit(&result);
    const attempt = switch (result) {
        .pending => |*pending| pending,
        .ready => return error.UnexpectedReadyListener,
    };
    var fds = [_]std.posix.pollfd{.{
        .fd = attempt.readinessFd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try net.poll.wait(&fds, 1000));
    const failure = switch (attempt.finish(allocator)) {
        .ready => return error.UnexpectedReadyListener,
        .failed => |value| value,
    };
    try std.testing.expectEqualStrings("UpgradeRefused", failure.primaryName());
    try relay.await(io);
}

test "keyed-relay listen owns a stalled initial registration asynchronously" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x6c)));
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    defer _ = resident.deinit();

    var connected = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(stallInitialRegistration, .{ io, &server, &connected, &release });
    defer {
        release.store(true, .release);
        relay.await(io) catch {};
    }

    var result = switch (resident.netlayer().listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    })) {
        .admitted => |result| result,
        .failed => |failure| return failure.cause,
    };
    defer netlayer_test.deinit(&result);
    try wait.untilFlag(io, wait.default_deadline_ms, &connected);
    const attempt = switch (result) {
        .pending => |*pending| pending,
        .ready => return error.UnexpectedReadyListener,
    };
    var pollfds: [1]std.posix.pollfd = undefined;
    try std.testing.expectEqual(null, try net.waitAnyReadable(&.{}, &pollfds, 20, &.{attempt.readinessFd()}));
}

test "keyed-relay listener close wakes and joins a parked readiness wait" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x6d)));
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    defer _ = resident.deinit();

    var pong_seen = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(holdParkedRegistration, .{ io, &server, &pong_seen });
    const listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    const expected_designator = identity.publicKey().toDesignator();
    const locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, locator);
    try std.testing.expectEqualStrings(&expected_designator, locator.designator);
    var wait_err: ?anyerror = null;
    var waiter = try io.concurrent(waitOnRegisteredListener, .{ listener, &wait_err });

    try wait.untilFlag(io, wait.default_deadline_ms, &pong_seen);
    netlayer_test.close(listener);
    waiter.await(io);
    try std.testing.expectEqual(error.ConnectionLost, wait_err.?);
    try relay.await(io);
}

fn serveOneRegistrationThenStallReplacement(
    io: Io,
    server: *ip.Server,
    replacement_seen: *std.atomic.Value(bool),
    drop_replacement: *std.atomic.Value(bool),
    dropped_replacement: *std.atomic.Value(bool),
    recovered_seen: *std.atomic.Value(bool),
    send_recovered: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),
) !void {
    var first: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    first.wire();
    defer first.close();
    try ws_relay.serveUpgrade(&first);
    try ws_relay.writeServerFrame(&first, .binary, "x");

    var replacement: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    replacement.wire();
    defer replacement.close();
    try ws_relay.serveUpgrade(&replacement);
    replacement_seen.store(true, .release);
    // The replacement parks after a valid upgrade. Inject a masked server
    // frame when asked: RFC 6455 forbids that shape, giving the repair barrier
    // one deterministic, transport-independent cause to retain.
    try wait.untilFlag(io, wait.default_deadline_ms, drop_replacement);
    try replacement.writer.interface.writeAll(&.{ 0x82, 0x80, 0, 0, 0, 0 });
    try replacement.writer.interface.flush();
    dropped_replacement.store(true, .release);

    var recovered: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    recovered.wire();
    defer recovered.close();
    try ws_relay.serveUpgrade(&recovered);
    recovered_seen.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, send_recovered);
    try ws_relay.writeServerFrame(&recovered, .binary, "recovered");
    try wait.untilFlag(io, wait.default_deadline_ms, release);
}

test "keyed-relay listener recovers a stalled replacement without invalidating its locator" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x6e)));
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    var resident_live = true;
    defer if (resident_live) std.debug.assert(resident.deinit() == null);

    var replacement_seen = std.atomic.Value(bool).init(false);
    var drop_replacement = std.atomic.Value(bool).init(false);
    var dropped_replacement = std.atomic.Value(bool).init(false);
    var recovered_seen = std.atomic.Value(bool).init(false);
    var send_recovered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(serveOneRegistrationThenStallReplacement, .{
        io,
        &server,
        &replacement_seen,
        &drop_replacement,
        &dropped_replacement,
        &recovered_seen,
        &send_recovered,
        &release,
    });
    defer {
        send_recovered.store(true, .release);
        release.store(true, .release);
        _ = relay.cancel(io) catch {};
    }

    var listener_arena = std.heap.ArenaAllocator.init(allocator);
    var listener_arena_live = true;
    defer if (listener_arena_live) listener_arena.deinit();
    const listener = try netlayer_test.listenBlocking(resident.netlayer(), listener_arena.allocator(), .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    var listener_live = true;
    defer if (listener_live) netlayer_test.close(listener);
    try std.testing.expect(try listener.waitAcceptable(1000));
    try std.testing.expect(!replacement_seen.load(.acquire));
    // The listener's replacement leg is its own lifetime. Destroying the
    // factory before accept must not leave that task borrowing URL slices.
    try std.testing.expectEqual(null, resident.deinit());
    resident_live = false;
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var conn = try listener.accept(&peer, .{ .read = &read_buf, .write = &write_buf });
    defer conn.deinit();

    try wait.untilFlag(io, wait.default_deadline_ms, &replacement_seen);
    const stalled_locator = try listener.localLocator(allocator);
    model.freePeerLocator(allocator, stalled_locator);
    try std.testing.expect(
        !try listener.waitAcceptable(20),
    );

    drop_replacement.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, &dropped_replacement);
    const recovering_locator = try listener.localLocator(allocator);
    model.freePeerLocator(allocator, recovering_locator);
    try wait.untilFlag(io, wait.default_deadline_ms, &recovered_seen);
    const recovery_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    var recovered_locator: model.PeerLocator = undefined;
    while (true) {
        recovered_locator = listener.localLocator(allocator) catch |err| switch (err) {
            error.BindFailed => {
                if (wait.expired(io, recovery_deadline)) return error.WaitTimedOut;
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
                continue;
            },
            else => return err,
        };
        break;
    }
    model.freePeerLocator(allocator, recovered_locator);
    send_recovered.store(true, .release);
    try std.testing.expect(try listener.waitAcceptable(1000));

    release.store(true, .release);
    const repair_failure = listener.close().?;
    try std.testing.expectEqualStrings("ProtocolViolation", repair_failure.primaryName());
    listener_live = false;

    // Accept transfers the pinned stream to the peer. Releasing every byte of
    // listener storage must leave the connection's interfaces and close handle
    // valid until the peer-owned connection is released.
    listener_arena.deinit();
    listener_arena_live = false;
    try std.testing.expect(conn.socketHandle() != null);
}
