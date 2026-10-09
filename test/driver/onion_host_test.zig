//! Host-tier onion loopback proof over the fake Tor daemon.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const support_actors = @import("../support/actors.zig");
const fake = @import("../support/onion_fake_daemon.zig");

const dial_opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const greeting = "hello from an onion service";
const Greeter = support_actors.StaticReplyValueActor("greet", greeting);

fn hostOnce(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

test "onion at the host tier: publish, dial, fetch, and call with no Tor" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.onion}, .onion = .{
        .socks = try net.tcp.parseDesignator(daemon.socksText()),
        .control = try net.tcp.parseDesignator(daemon.controlText()),
    } }, model.transport.onion, .{ .designator = "" }, .ephemeral, dial_opts);
    defer server.deinit();

    var designator_buf: [128]u8 = undefined;
    const designator = try server.localDesignator(&designator_buf);
    try std.testing.expectEqualStrings(fake.service_id, designator);

    var empty: [0]u8 = .{};
    try std.testing.expectEqual(
        @as(?usize, fake.service_key.len),
        try server.restorationState(&empty),
    );
    var short: [fake.service_key.len - 1]u8 = @splat(0xa5);
    try std.testing.expectEqual(
        @as(?usize, fake.service_key.len),
        try server.restorationState(&short),
    );
    const expected_short: [short.len]u8 = @splat(0xa5);
    try std.testing.expectEqualSlices(u8, &expected_short, &short);
    var restoration_key: [fake.service_key.len]u8 = undefined;
    try std.testing.expectEqual(
        @as(?usize, fake.service_key.len),
        try server.restorationState(&restoration_key),
    );
    try std.testing.expectEqualStrings(fake.service_key, &restoration_key);

    var host_future = try io.concurrent(hostOnce, .{server});
    var splice = try io.concurrent(fake.Daemon.spliceDial, .{daemon});

    const client_result = clientHalf(allocator, io, daemon.socksText());
    const host_result = host_future.await(io);
    try splice.await(io);
    try client_result;
    try host_result;
}

fn clientHalf(allocator: std.mem.Allocator, io: std.Io, socks: []const u8) !void {
    const transports: driver.Transports = .{ .symbols = &.{.onion}, .onion = .{ .socks = try net.tcp.parseDesignator(socks) } };
    var session = try driver.connect(allocator, io, transports, .{
        .transport = model.transport.onion,
        .designator = fake.service_id,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const greeter = try session.fetch("greeter");
    const reply = try session.call(greeter, "greet", &.{}, arena_state.allocator());
    try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
    try std.testing.expectEqualStrings(greeting, reply.fulfilled.string);
}

const next_opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
    .codec = .capnp,
    .captp_version = .next,
};

test "onion profile by knowledge: a hinted dial settles glowcap-next, a bare dial the baseline" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.onion}, .onion = .{
        .socks = try net.tcp.parseDesignator(daemon.socksText()),
        .control = try net.tcp.parseDesignator(daemon.controlText()),
    } }, model.transport.onion, .{ .designator = "" }, .ephemeral, next_opts);
    defer server.deinit();

    // Handed the glowcap-hinted form of the address, the dialer knows its
    // acceptor is glowcap, states its real preference, and the deferred
    // acceptor hello mirrors it (ADR-0118). The session settles the full
    // configured profile and carries a call on it.
    {
        var host_future = try io.concurrent(hostOnce, .{server});
        var splice = try io.concurrent(fake.Daemon.spliceDial, .{daemon});
        const client_result = profileClient(allocator, io, daemon.socksText(), .hinted, .next, .capnp);
        const host_result = host_future.await(io);
        try splice.await(io);
        try client_result;
        try host_result;
    }

    // The bare canonical form mints no knowledge: both hellos stay bare and
    // the same two peers settle the baseline, exactly what a Goblins partner
    // would observe on this wire.
    {
        var host_future = try io.concurrent(hostOnce, .{server});
        var splice = try io.concurrent(fake.Daemon.spliceDial, .{daemon});
        const client_result = profileClient(allocator, io, daemon.socksText(), .bare, .v1_0, .syrup);
        const host_result = host_future.await(io);
        try splice.await(io);
        try client_result;
        try host_result;
    }
}

fn profileClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    socks: []const u8,
    form: enum { hinted, bare },
    want_version: model.CaptpVersion,
    want_codec: model.CodecId,
) !void {
    const transports: driver.Transports = .{ .symbols = &.{.onion}, .onion = .{ .socks = try net.tcp.parseDesignator(socks) } };
    const profile_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_captp_version,
        .value = .{ .string = model.CaptpVersion.next.wireString() },
    }};
    var session = try driver.connect(allocator, io, transports, .{
        .transport = model.transport.onion,
        .designator = fake.service_id,
        .hints = switch (form) {
            .hinted => .{ .entries = &profile_hints },
            .bare => model.Hints.emptyFalse(),
        },
    }, .ephemeral, next_opts);
    defer session.deinit();

    const state = &session.hs.served.port.peer.session_state;
    try std.testing.expectEqual(want_version, state.captp_version);
    try std.testing.expectEqual(want_codec, state.codec);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const greeter = try session.fetch("greeter");
    const reply = try session.call(greeter, "greet", &.{}, arena_state.allocator());
    try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
    try std.testing.expectEqualStrings(greeting, reply.fulfilled.string);
}
