//! The netlayer contract, proven through its first resident.
//!
//! These run the same loopback as `tcp_test.zig`: handshake to open, bootstrap
//! fetch round-trip over a real 127.0.0.1 socket, but route every step through
//! the runtime contract instead of tcp's concrete functions: the server binds
//! with `Netlayer.listen` and accepts with the contract `Listener`, the client
//! dials with `Netlayer.dial`. If the resident is a faithful transport behind
//! the vtable, this passes exactly as the direct tcp loopback does. A slice
//! test pins `resolve`.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../support/netlayer.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;
const tcp = net.tcp;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const frame_cap = 4096;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

fn unusedDialFinish(
    _: *anyopaque,
    _: *anyopaque,
    _: *engine.Peer,
    _: net.netlayer.Buffers,
) net.netlayer.DialFinishOutcome {
    return .{ .failed = .init(error.ConnectionLost) };
}

fn unusedDialCancel(_: *anyopaque, _: *anyopaque) ?glowcap.foundation.FailureChain {
    return null;
}

fn unusedListenFinish(
    _: *anyopaque,
    _: *anyopaque,
    _: std.mem.Allocator,
) net.netlayer.ListenFinishOutcome {
    return .{ .failed = .init(error.BindFailed) };
}

fn unusedListenCancel(_: *anyopaque, _: *anyopaque) ?net.netlayer.ListenerCloseFailure {
    return null;
}

/// Accept one partner through the contract `Listener`, handshake, and serve the
/// bootstrap fetch until the client closes.
fn serveOnce(listener: *net.netlayer.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, .{ .read = read_buf, .write = write_buf });
    defer conn.deinit();

    try peer.sendCopying(startSession("server"));

    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

/// Dial through `Netlayer.dial`, handshake to open, fetch `thermostat`, assert it
/// settles fulfilled.
fn fetchOnce(nl: net.netlayer.Netlayer, designator: []const u8, allocator: std.mem.Allocator) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try nl.dial(&peer, locator, .{ .read = read_buf, .write = write_buf }, .inherit);
    defer conn.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("client"));

    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

test "netlayer slice resolves a transport symbol and misses the rest" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var resident = tcp.Resident{ .io = threaded.io() };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};

    const found = net.netlayer.resolve(&netlayers, "tcp") orelse return error.TcpNotResolved;
    try std.testing.expectEqualStrings("tcp", found.transportName());
    try std.testing.expect(net.netlayer.resolve(&netlayers, "quic") == null);
}

test "consumed operation shells refuse a second finish without trapping" {
    var peer = stubNegotiatingPeer(std.testing.allocator);
    defer peer.deinit();
    const dial_vtable: net.netlayer.DialAttempt.VTable = .{
        .finish = unusedDialFinish,
        .cancel = unusedDialCancel,
    };
    var dial = net.netlayer.DialAttempt{
        .owner = undefined,
        .attempt = null,
        .vtable = &dial_vtable,
        .readiness_fd = -1,
    };
    const dial_failure = dial.finish(&peer, .{ .read = &.{}, .write = &.{} }).failed;
    try std.testing.expectEqual(error.InvalidOptions, dial_failure.classification);

    var listen = net.netlayer.ListenAttempt{
        .owner = undefined,
        .attempt = null,
        .finish_fn = unusedListenFinish,
        .cancel_fn = unusedListenCancel,
        .readiness_fd = -1,
    };
    const listen_failure = listen.finish(std.testing.allocator).failed;
    try std.testing.expectEqual(error.ProviderContract, listen_failure.cause);

    var claimed = net.multiplexed_resident.ClaimedConnection{
        .resident = undefined,
        .id = null,
    };
    try std.testing.expect(claimed.borrow() == null);
    try std.testing.expect(claimed.take() == null);

    const pending_teardown: net.multiplexed_resident.TeardownOutcome = .pending;
    const pending_failure = pending_teardown.requireComplete().?;
    try std.testing.expectEqualStrings("ProviderContract", pending_failure.primaryName());

    const empty_vtable: net.netlayer.Netlayer.VTable = .{
        .profile = model.transport.Known.tcp.metadata(),
        .dial = null,
        .listen = null,
    };
    const empty = net.netlayer.Netlayer{ .ctx = undefined, .vtable = &empty_vtable };
    const locator = tcp.locator("127.0.0.1:1");
    try std.testing.expectError(
        error.InvalidOptions,
        empty.dial(&peer, locator, .{ .read = &.{}, .write = &.{} }, .inherit),
    );
    try std.testing.expectEqual(
        error.InvalidOptions,
        empty.startDial(locator, .inherit).failed.classification,
    );
    try std.testing.expectEqual(
        error.InvalidOptions,
        empty.listen(std.testing.allocator, .{ .designator = "" }).failed.cause,
    );
}

test "netlayer contract loopback: dial + accept through the vtable, handshake + fetch" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = tcp.Resident{ .io = io };
    const nl = resident.netlayer();

    var listener = try netlayer_test.listenBlocking(nl, allocator, .{ .designator = "127.0.0.1:0" });
    defer netlayer_test.close(listener);

    const locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, locator);

    var server_future = try io.concurrent(serveOnce, .{ &listener, allocator });

    const client_result = fetchOnce(nl, locator.designator, allocator);
    const server_result = server_future.await(io);

    try client_result;
    try server_result;
}
