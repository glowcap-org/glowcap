//! The relay symbols on HostRuntime through completion residents (ADR-0018):
//! the listening resident registers the Host's identity with a relay, and a
//! dialing resident that names the key reaches it through the rendezvous.
//! `noise-relay` rides the same socket, sealed by the Host on both halves
//! (ADR-0041), so the relay forwards ciphertext and the dial proves the key.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const ws_relay = @import("../../support/ws_relay.zig");
const wait = @import("../../support/wait.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;

const RelayBackend = net.KeyedRelayBackend;
const RelayResident = net.completion_resident.Resident(RelayBackend, net.relay.ResidentPolicy(RelayBackend, net.tcp.CompletionPolicy(net.Backend)));

const frame_cap = 4096;

const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const reply = "pong through the relay";

const Echo = struct {
    pub fn handle(_: *Echo, _: *driver.HostTurn, verb: []const u8, _: driver.Args) !driver.Value {
        if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
        return .{ .string = reply };
    }
};

fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("echo", Echo, .{});
    while (!done.load(.acquire)) {
        _ = session.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

/// `late_relay` starts the relay only after the listener's first
/// registration attempt has failed, so only the runtime's own timer can
/// bring the registration back: nothing else wakes the accepting wait.
fn exercise(transport: model.transport.Known, late_relay: bool) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const symbol = transport.metadata().symbol;

    const relay_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var relay_server = try std.Io.net.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    const port = relay_server.socket.address.getPort();
    const relay_at: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    if (late_relay) relay_server.deinit(io);
    defer relay_server.deinit(io);
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    var registered = std.atomic.Value(bool).init(false);
    // The relay scans every forwarded payload for the reply's plaintext.
    var relay_saw_reply = std.atomic.Value(bool).init(false);
    const probe: ws_relay.Probe = .{ .needle = reply, .found = &relay_saw_reply, .registered = &registered };
    var relay_future: ?@TypeOf(try io.concurrent(ws_relay.bridgeOneRendezvousObserved, .{ io, &relay_server, allocator, probe })) = null;
    if (!late_relay) relay_future = try io.concurrent(ws_relay.bridgeOneRendezvousObserved, .{ io, &relay_server, allocator, probe });
    errdefer if (relay_future) |*future| future.cancel(io) catch {};

    const seed: [crypto.seed_bytes]u8 = @splat(0x74);
    const secret = crypto.SecretKey.fromSeed(seed);
    const identity = secret.publicKey();
    const designator = identity.toDesignator();

    var entropy: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&entropy);
    var relay_resident = try RelayResident.init(allocator, try RelayBackend.initWithRelay(allocator, 64, 16, frame_cap, .{
        .url = relay_url,
        .entropy_seed = entropy,
        .registration = .{ .url = register_url },
    }), .{});
    defer retire(&relay_resident);
    const registrations = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = transport.metadata(),
        .resident = relay_resident.resident(),
    }};
    var server = try driver.listen(allocator, io, .{ .residents = &registrations }, symbol, .{ .designator = &designator }, .{ .keyed = secret }, dial_opts);
    defer server.deinit();
    const advertised = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, advertised);
    try std.testing.expectEqualStrings(symbol, advertised.transport);
    try std.testing.expectEqualStrings(&designator, advertised.designator);
    // The locator names the backend's relay as its rendezvous hint.
    const relay_hint = for (advertised.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "rendezvous-relay")) break entry.value.string;
    } else return error.MissingRelayHint;
    try std.testing.expectEqualStrings(relay_url, relay_hint);

    var done = std.atomic.Value(bool).init(false);
    var server_future = try io.concurrent(serve, .{ server, &done });
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }

    if (late_relay) {
        // tolerant: an interrupted sleep only brings the relay up sooner.
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .real) catch {};
        relay_server = try std.Io.net.IpAddress.listen(&relay_at, io, .{ .reuse_address = true });
        relay_future = try io.concurrent(ws_relay.bridgeOneRendezvousObserved, .{ io, &relay_server, allocator, probe });
    }

    // The fixture takes the registration as its first leg; dial after it.
    const deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!registered.load(.acquire)) {
        if (wait.expired(io, deadline)) return error.WaitTimedOut;
        // tolerant: an interrupted sleep only rechecks the flag sooner.
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }

    try io.randomSecure(&entropy);
    var dialer_resident = try RelayResident.init(allocator, try RelayBackend.initWithRelay(allocator, 64, 16, frame_cap, .{
        .url = relay_url,
        .entropy_seed = entropy,
    }), .{});
    defer retire(&dialer_resident);
    {
        var client = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, dial_opts);
        defer client.deinit();
        _ = try client.addResident(transport.metadata(), dialer_resident.resident());
        const hs = try client.connectLocator(advertised, .inherit);
        const view = try driver.Session.adopt(&client, hs);
        defer view.deinit();
        const proved = (try client.core.partnerIdentity(hs)).durableIdentityAuthenticated();
        try std.testing.expectEqual(transport.metadata().sealed_channel, proved);

        const echo = try view.fetch("echo");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        switch (try view.call(echo, "ping", &.{}, arena.allocator())) {
            .fulfilled => |arg| try std.testing.expectEqualStrings(reply, arg.string),
            .broken => |reason| {
                std.debug.print("echo broke: {s}\n", .{reason});
                return error.EchoBroke;
            },
        }
    }

    try relay_future.?.await(io);
    // A sealed symbol hands the relay ciphertext only; the keyed-relay run
    // proves the same probe sees the reply when it travels in the clear.
    try std.testing.expectEqual(!transport.metadata().sealed_channel, relay_saw_reply.load(.acquire));
}

fn retire(resident: *RelayResident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("relay resident drain failed: {t}", .{err});
    resident.deinit();
}

test "a relay completion resident accepts a keyed-relay dial through its registration" {
    try exercise(.keyed_relay, false);
}

test "noise-relay rides the relay residents, sealed and proved by the Host, through a ciphertext-only relay" {
    try exercise(.noise_relay, false);
}

test "a relay registration refused at first retries on the runtime's own timer" {
    try exercise(.keyed_relay, true);
}
