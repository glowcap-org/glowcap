//! Deployment route aliases select the same registry before carrier opening.
//! Both Zig execution paths share this policy. Peer hints remain untrusted.
const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../../support/keyed_relay_admission.zig");
const ws_relay = @import("../../support/ws_relay.zig");
const relay = glowcap.net.relay;
const model = glowcap.ocapn.model;
const public_route = "wss://rooms.example/relay";
const internal_route = "ws://127.0.0.1:8080/relay";

test "relay alias selects only the configured endpoint and retains owned bytes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const alias = try std.testing.allocator.dupe(u8, public_route);
    defer std.testing.allocator.free(alias);
    var resident = try relay.Resident.initConfigured(std.testing.allocator, threaded.io(), .{
        .relay_url = internal_route,
        .relay_alias_url = alias,
    }, .keyed, null);
    defer std.testing.expect(resident.deinit() == null) catch unreachable;
    @memset(alias, 'x');
    const config = resident.configuration();
    for ([_][]const u8{ public_route, "wss://ROOMS.EXAMPLE:443/relay" }) |hint| {
        const selected = config.selectDialRoute(try relay.RelayUrl.parse(hint));
        try std.testing.expectEqualStrings("127.0.0.1", selected.host);
        try std.testing.expectEqual(@as(u16, 8080), selected.port);
        try std.testing.expectEqual(relay.Scheme.ws, selected.scheme);
    }
    for ([_][]const u8{
        "wss://elsewhere.example/relay",
        "wss://rooms.example/other",
        "wss://rooms.example/relay?other=1",
        "wss://rooms.example:444/relay",
        "ws://rooms.example/relay",
        "wss://rooms.example.evil/relay",
    }) |hint| {
        const parsed = try relay.RelayUrl.parse(hint);
        const selected = config.selectDialRoute(parsed);
        try std.testing.expectEqualStrings(parsed.authority, selected.authority);
        try std.testing.expectEqual(parsed.scheme, selected.scheme);
        try std.testing.expectEqualStrings(parsed.path, selected.path);
        try std.testing.expectEqualStrings(parsed.query orelse "", selected.query orelse "");
    }
    try std.testing.expectEqual(@as(u16, 8080), config.selectDialRoute(null).port);
    try std.testing.expectError(error.InvalidRelayUrl, (relay.Configuration{
        .relay_url = internal_route,
        .relay_alias_url = "https://rooms.example/relay",
    }).validate());
}

test "relay alias changes provider equivalence and does not admit malformed peer hints" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var aliased = try relay.Resident.initConfigured(std.testing.allocator, threaded.io(), .{
        .relay_url = internal_route,
        .relay_alias_url = public_route,
    }, .keyed, null);
    defer std.testing.expect(aliased.deinit() == null) catch unreachable;
    var plain = try relay.Resident.init(std.testing.allocator, threaded.io(), internal_route);
    defer std.testing.expect(plain.deinit() == null) catch unreachable;
    try std.testing.expect(!aliased.configuration().same(plain.configuration().*));
    const designator = glowcap.foundation.crypto.SecretKey.fromSeed(@splat(0x56)).publicKey().toDesignator();
    const hints = [_]model.HintEntry{
        .{ .name = relay.rendezvous_relay_hint, .value = .{ .string = public_route } },
        .{ .name = relay.rendezvous_relay_hint, .value = .{ .string = public_route } },
    };
    const outcome = aliased.dialRawOutcome(.{
        .transport = relay.transport_name,
        .designator = &designator,
        .hints = .{ .entries = &hints },
    });
    try std.testing.expectEqual(error.InvalidAddress, outcome.failed.classification);
}

fn acceptAlias(io: std.Io, server: *std.Io.net.Server, designator: []const u8) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    defer leg.close();
    leg.wire();
    try ws_relay.serveUpgrade(&leg);
    var target: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&target, "/relay?rendezvous={s}", .{designator}),
        leg.target,
    );
}

test "relay alias opens a public WSS hint through the internal pollable carrier" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var url: [64]u8 = undefined;
    var resident = try relay.Resident.initConfigured(std.testing.allocator, io, .{
        .relay_url = try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/relay", .{server.socket.address.getPort()}),
        .relay_alias_url = public_route,
    }, .noise, null);
    defer std.testing.expect(resident.deinit() == null) catch unreachable;
    const designator = glowcap.foundation.crypto.SecretKey.fromSeed(@splat(0x57)).publicKey().toDesignator();
    var plain = try relay.Resident.initProfile(std.testing.allocator, io, resident.configuration().relay_url_text, .noise);
    defer std.testing.expect(plain.deinit() == null) catch unreachable;
    var plain_hints: [1]model.HintEntry = undefined;
    const refused = plain.dialRawOutcome(relay.noise.locator(&designator, public_route, &plain_hints));
    try std.testing.expectEqualStrings("SecureCarrierUnavailable", refused.failed.chain.primaryName());
    var future = try io.concurrent(acceptAlias, .{ io, &server, &designator });
    defer _ = future.cancel(io) catch {};
    var hints: [1]model.HintEntry = undefined;
    const outcome = resident.dialRawOutcome(relay.noise.locator(&designator, public_route, &hints));
    var connection = switch (outcome) {
        .connected => |value| value,
        .failed => |failure| {
            std.debug.print("alias dial failed: {s}\n", .{failure.chain.primaryName()});
            return error.UnexpectedDialFailure;
        },
    };
    defer _ = connection.close();
    try future.await(io);
}

test "relay alias opens a public WSS hint through the internal completion carrier" {
    var backend = try admission.AdmissionBackend.initWithRelay(std.testing.allocator, 8, 1, 64, .{
        .url = internal_route,
        .relay_alias_url = public_route,
        .entropy_seed = @splat(0x58),
    });
    defer admission.deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));
    _ = try backend.startDial(9, .{ .keyed_relay = .{
        .designator = &designator,
        .relay = try relay.RelayUrl.parse(public_route),
    } });
    try std.testing.expectEqual(@as(usize, 1), backend.platform.dial_submits);
    var completions: [1]glowcap.net.completion.Completion = undefined;
    _ = try backend.poll(&completions, 0);
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
}
