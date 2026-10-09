//! Relay listening on the completion backend: a registration leg parks at
//! the relay, answers its ping, and becomes the accepted connection when a
//! dialer's first bytes arrive. Bytes then cross both ways, and closing the
//! listener retires the replacement leg it started.

const std = @import("std");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const net = glowcap.net;
const completion = net.completion;
const ws_relay = @import("../../support/ws_relay.zig");

const Backend = net.KeyedRelayBackend;
const Io = std.Io;
const ip = std.Io.net;

fn registrationParked(backend: *Backend) bool {
    const leg = backend.registration.leg orelse return false;
    const c = backend.conns.get(leg.id) orelse return false;
    return c.state == .parked;
}

/// Poll every backend in turn until `owner` reports `user_data`. Any other
/// completion is a failure: each step here expects exactly one.
fn awaitOn(backends: []const *Backend, owner: *Backend, user_data: u64) !completion.Completion {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        for (backends) |backend| {
            var out: [4]completion.Completion = undefined;
            const n = try backend.poll(&out, 10);
            for (out[0..n]) |comp| {
                if (backend == owner and comp.user_data == user_data) return comp;
                std.debug.print("unexpected completion {d}\n", .{comp.user_data});
                return error.UnexpectedCompletion;
            }
        }
    }
    return error.CompletionTimedOut;
}

fn expectRecv(backends: []const *Backend, owner: *Backend, fd: Backend.Fd, user_data: u64, expected: []const u8) !void {
    try owner.submitRecv(user_data, fd);
    const comp = try awaitOn(backends, owner, user_data);
    defer if (comp.borrowed.active()) owner.recycleBorrowed(comp);
    try std.testing.expectEqualStrings(expected, comp.borrowed.recvBytes() orelse "");
}

test "keyed-relay completion listener accepts a dialer through its registration" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var relay_server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x72))).publicKey();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &relay_server, allocator });
    errdefer relay_future.cancel(io) catch {};

    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    var listener = try Backend.initWithRelay(allocator, 64, 8, 4096, .{
        .url = relay_url,
        .entropy_seed = seed,
        .registration = .{ .url = register_url },
    });
    defer listener.deinit();
    try io.randomSecure(&seed);
    var dialer = try Backend.initWithRelay(allocator, 64, 8, 4096, .{ .url = relay_url, .entropy_seed = seed });
    defer dialer.deinit();
    const backends = [_]*Backend{ &listener, &dialer };

    const listen_fd = try listener.openListener(.{ .relay = identity });
    try std.testing.expectEqual(Backend.ListenerAddress.relay, try listener.listenerAddress(listen_fd));
    try listener.submitAccept(1, listen_fd);

    // The fixture takes the registration first, so the dial waits for it.
    var turns: usize = 0;
    while (!registrationParked(&listener)) : (turns += 1) {
        if (turns == 500) return error.RegistrationNeverParked;
        var out: [4]completion.Completion = undefined;
        try std.testing.expectEqual(@as(usize, 0), try listener.poll(&out, 10));
    }

    const designator = identity.toDesignator();
    const dial_fd = try dialer.startDial(2, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    try std.testing.expectEqual(@as(i32, 0), (try awaitOn(&backends, &dialer, 2)).result);
    // The relay pairs the legs at once, but the listener learns of the dialer
    // from its first bytes.
    try dialer.submitSend(3, dial_fd, "hello");
    try std.testing.expectEqual(@as(i32, 5), (try awaitOn(&backends, &dialer, 3)).result);
    const accepted = try awaitOn(&backends, &listener, 1);
    try std.testing.expectEqual(@as(i32, 0), accepted.result);
    const accepted_fd = accepted.accepted_fd.?;
    try expectRecv(&backends, &listener, accepted_fd, 4, "hello");

    try listener.submitSend(5, accepted_fd, "world");
    try std.testing.expectEqual(@as(i32, 5), (try awaitOn(&backends, &listener, 5)).result);
    try expectRecv(&backends, &dialer, dial_fd, 6, "world");

    // Promotion started a replacement leg; closing the listener retires it.
    try std.testing.expect(listener.registration.leg != null);
    try listener.submitClose(7, listen_fd);
    try std.testing.expectEqual(@as(i32, 0), (try awaitOn(&backends, &listener, 7)).result);
    try std.testing.expect(listener.registration.leg == null and listener.registration.unaccepted_len == 0);

    try dialer.submitClose(8, dial_fd);
    _ = try awaitOn(&backends, &dialer, 8);
    try listener.submitClose(9, accepted_fd);
    _ = try awaitOn(&backends, &listener, 9);
    try relay_future.await(io);
}

/// Take a registration, drop it with a close frame, and expect the listener
/// to register the same id again.
fn dropThenExpectRegistration(io: Io, server: *ip.Server, done: *std.atomic.Value(bool)) !void {
    defer done.store(true, .release);
    var first: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    first.wire();
    try ws_relay.serveUpgrade(&first);
    var id_store: [128]u8 = undefined;
    const id = id_store[0..first.target.len];
    @memcpy(id, first.target);
    try ws_relay.writeServerFrame(&first, .close, &.{});
    first.close();

    var second: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    second.wire();
    defer second.close();
    try ws_relay.serveUpgrade(&second);
    try std.testing.expectEqualStrings(id, second.target);
}

test "keyed-relay completion listener registers again after the relay drops it" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var relay_server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x73))).publicKey();

    var done = std.atomic.Value(bool).init(false);
    var relay_future = try io.concurrent(dropThenExpectRegistration, .{ io, &relay_server, &done });
    errdefer relay_future.cancel(io) catch {};

    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    var listener = try Backend.initWithRelay(allocator, 64, 8, 4096, .{
        .url = register_url,
        .entropy_seed = seed,
        .registration = .{ .url = register_url },
    });
    defer listener.deinit();
    const listen_fd = try listener.openListener(.{ .relay = identity });

    var turns: usize = 0;
    while (!done.load(.acquire)) : (turns += 1) {
        if (turns == 500) return error.RegistrationNeverReplaced;
        var out: [4]completion.Completion = undefined;
        try std.testing.expectEqual(@as(usize, 0), try listener.poll(&out, 10));
    }
    try relay_future.await(io);
    try listener.submitClose(1, listen_fd);
    const backends = [_]*Backend{&listener};
    try std.testing.expectEqual(@as(i32, 0), (try awaitOn(&backends, &listener, 1)).result);
}
