//! Relay URL admission. Live DNS acquisition is exercised by the resident
//! loopback in `keyed_relay_test.zig`; these cases pin the bounded grammar.

const std = @import("std");
const glowcap = @import("glowcap");
const keyed_relay = glowcap.net.relay;
const ws_relay = @import("../support/ws_relay.zig");

const IdentityTls = struct {
    hostname_ok: bool = false,
    clients_closed: usize = 0,
    runtime_closed: usize = 0,
    refuse_runtime_close_once: bool = false,
    refuse_client_close: bool = false,

    fn runtime(self: *IdentityTls) glowcap.net.tls.runtime.Runtime {
        return .{ .ctx = self, .vtable = &runtime_vtable };
    }

    fn open(raw: *anyopaque, hostname: []const u8) glowcap.net.tls.runtime.OpenOutcome {
        const self: *IdentityTls = @ptrCast(@alignCast(raw));
        self.hostname_ok = std.mem.eql(u8, hostname, "127.0.0.1");
        return .{ .client = .init(self, &client_vtable) };
    }

    fn closeRuntime(raw: *anyopaque) ?glowcap.foundation.FailureChain {
        const self: *IdentityTls = @ptrCast(@alignCast(raw));
        self.runtime_closed += 1;
        if (self.refuse_runtime_close_once) {
            self.refuse_runtime_close_once = false;
            return .init(error.InjectedTlsRuntimeClose);
        }
        return null;
    }

    fn sameRuntime(left_raw: *anyopaque, right_raw: *anyopaque) bool {
        return left_raw == right_raw;
    }

    fn step(_: *anyopaque, phase: glowcap.net.tls.engine.Phase, exchange: glowcap.net.tls.engine.Exchange) glowcap.net.tls.engine.RawOutcome {
        return switch (phase) {
            .handshake => .{ .stepped = .{ .status = .established } },
            .transmit => copy(.transmit, exchange.plaintext_in, exchange.ciphertext_out),
            .receive => if (exchange.ciphertext_in.len == 0)
                .{ .stepped = .{ .interest = .{ .read = true } } }
            else
                copy(.receive, exchange.ciphertext_in, exchange.plaintext_out),
            .shutdown => .{ .stepped = .{ .status = .clean_close } },
        };
    }

    fn copy(
        phase: glowcap.net.tls.engine.Phase,
        input: []const u8,
        output: []u8,
    ) glowcap.net.tls.engine.RawOutcome {
        const count = @min(input.len, output.len);
        @memcpy(output[0..count], input[0..count]);
        var transfer = glowcap.net.tls.engine.Transfer{};
        if (phase == .transmit) {
            transfer.plaintext_consumed = count;
            transfer.ciphertext_produced = count;
        } else {
            transfer.ciphertext_consumed = count;
            transfer.plaintext_produced = count;
        }
        return .{ .stepped = .{ .transfer = transfer } };
    }

    fn closeClient(raw: *anyopaque) ?glowcap.foundation.FailureChain {
        const self: *IdentityTls = @ptrCast(@alignCast(raw));
        self.clients_closed += 1;
        if (self.refuse_client_close) return .init(error.InjectedTlsClientClose);
        return null;
    }

    const runtime_vtable: glowcap.net.tls.runtime.Runtime.VTable = .{
        .open = open,
        .same_configuration = sameRuntime,
        .deinit_outcome = closeRuntime,
    };
    const client_vtable: glowcap.net.tls.engine.VTable = .{
        .step = step,
        .deinit = closeClient,
    };
};

test "RelayUrl admits clear and secure IP and DNS endpoints" {
    const ip = try keyed_relay.RelayUrl.parse("ws://127.0.0.1:8000/relay");
    try std.testing.expectEqual(keyed_relay.Scheme.ws, ip.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", ip.host);
    try std.testing.expectEqual(@as(u16, 8000), ip.port);
    try std.testing.expectEqualStrings("/relay", ip.path);
    try std.testing.expectEqualStrings("127.0.0.1:8000", ip.authority);

    const ip6 = try keyed_relay.RelayUrl.parse("ws://[::1]:9000");
    try std.testing.expectEqualStrings("::1", ip6.host);
    try std.testing.expectEqualStrings("[::1]:9000", ip6.authority);

    const dns = try keyed_relay.RelayUrl.parse("wss://Relay.Example/relay?deployment=local");
    try std.testing.expectEqual(keyed_relay.Scheme.wss, dns.scheme);
    try std.testing.expectEqualStrings("Relay.Example", dns.host);
    try std.testing.expectEqual(@as(u16, 443), dns.port);
    try std.testing.expectEqualStrings("Relay.Example", dns.authority);
    try std.testing.expectEqualStrings("/relay", dns.path);
    try std.testing.expectEqualStrings("?deployment=local", dns.query.?);

    const default_clear = try keyed_relay.RelayUrl.parse("ws://relay.example");
    try std.testing.expectEqual(@as(u16, 80), default_clear.port);
    try std.testing.expectEqualStrings("relay.example", default_clear.authority);
}

test "RelayUrl refuses unsupported or ambiguous HTTP endpoints" {
    const invalid = [_][]const u8{
        "http://relay.example:80/x",
        "ws://user@relay.example:80/x",
        "ws://user:pass@relay.example:80/x",
        "ws://relay.example:0/x",
        "ws://bad_host.example:80/x",
        "ws://::1:9000/relay",
        "ws://relay.example:80/relay\r\nInjected: yes",
        "ws://relay.example:80/a path",
        "ws://relay.example:80/relay#local",
        "ws://relay.example:80/relay?broken=%",
        "ws://relay.example:80/relay?rendezvous=shadow",
        "ws://relay.example:80/relay?x=1&id=shadow",
        "ws://relay.example:80/relay?%72endezvous=shadow",
        "ws://relay.example:80/relay?%69%64=shadow",
    };
    for (invalid) |url|
        try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse(url));
}

test "relay route corpus pins native admission and byte-exact request targets" {
    const Case = struct {
        route: []const u8,
        request_target: []const u8,
    };
    const Corpus = struct {
        designator: []const u8,
        accepted: []const Case,
        rejected: []const []const u8,
    };
    const parsed = try std.json.parseFromSlice(
        Corpus,
        std.testing.allocator,
        @embedFile("fixtures/relay_routes.json"),
        .{},
    );
    defer parsed.deinit();

    for (parsed.value.accepted) |case| {
        const url = try keyed_relay.RelayUrl.parse(case.route);
        const request = url.openRequest(.rendezvous, parsed.value.designator);
        const target = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{c}{s}={s}", .{
            request.path(),
            request.fixedQueryPrefix(),
            request.queryJoin(),
            request.queryName(),
            request.query_value,
        });
        defer std.testing.allocator.free(target);
        try std.testing.expectEqualStrings(case.request_target, target);
    }
    for (parsed.value.rejected) |route_text|
        try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse(route_text));
}

test "OpenRequest owns the relay query selection before carrier I/O" {
    const url = try keyed_relay.RelayUrl.parse("ws://relay.example:8000/relay?deployment=local");
    const request = url.openRequest(.rendezvous, "abc123");
    try std.testing.expectEqualStrings("relay.example", request.endpoint.host);
    try std.testing.expectEqualStrings("/relay", request.path());
    try std.testing.expectEqualStrings("?deployment=local", request.fixedQueryPrefix());
    try std.testing.expectEqual('&', request.queryJoin());
    try std.testing.expectEqualStrings("rendezvous", request.queryName());
    try std.testing.expectEqualStrings("abc123", request.query_value);
}

test "secure routes fail closed before the clear carrier performs I/O" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var resident = try keyed_relay.Resident.init(
        allocator,
        threaded.io(),
        "wss://127.0.0.1:1/relay",
    );
    defer _ = resident.deinit();
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x72)),
    );
    const designator = identity.publicKey().toDesignator();
    var stop = std.atomic.Value(bool).init(false);
    const outcome = resident.dialRawOutcomeCancelable(.{
        .transport = keyed_relay.transport_name,
        .designator = &designator,
    }, &stop);
    switch (outcome) {
        .connected => |connected| {
            var connection = connected;
            _ = connection.close();
            return error.TestExpectedError;
        },
        .failed => |failure| {
            try std.testing.expectEqual(error.SocketConfigurationFailed, failure.classification);
            try std.testing.expectEqualStrings("SecureCarrierUnavailable", failure.chain.primaryName());
        },
    }
}

fn acceptIdentityTls(io: std.Io, server: *std.Io.net.Server) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
}

fn refuseIdentityTlsUpgrade(io: std.Io, server: *std.Io.net.Server) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    var matched: usize = 0;
    while (matched != 4) {
        const byte = try leg.reader.interface.takeByte();
        const marker = "\r\n\r\n";
        matched = if (byte == marker[matched]) matched + 1 else 0;
    }
    try leg.writer.interface.writeAll("HTTP/1.1 403 Refused\r\n\r\n");
    try leg.writer.interface.flush();
}

test "secure relay keeps upgrade primary ahead of TLS cleanup refusal" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const listen_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var accepted = try io.concurrent(refuseIdentityTlsUpgrade, .{ io, &server });

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "wss://127.0.0.1:{d}/relay", .{server.socket.address.getPort()});
    var identity_tls = IdentityTls{ .refuse_client_close = true };
    var tls_runtime = identity_tls.runtime();
    var resident = try keyed_relay.Resident.initProfileWithTls(
        allocator,
        io,
        url,
        .keyed,
        &tls_runtime,
    );
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x76)),
    );
    const designator = identity.publicKey().toDesignator();
    var stop = std.atomic.Value(bool).init(false);
    const outcome = resident.dialRawOutcomeCancelable(.{
        .transport = keyed_relay.transport_name,
        .designator = &designator,
    }, &stop);
    const failure = switch (outcome) {
        .connected => return error.TestExpectedError,
        .failed => |value| value,
    };
    try std.testing.expectEqual(error.ConnectionRefused, failure.classification);
    try std.testing.expectEqualStrings("UpgradeRefused", failure.chain.primaryName());
    try std.testing.expectEqualStrings("InjectedTlsClientClose", failure.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.chain.secondary_count);
    try accepted.await(io);
    try std.testing.expect(resident.deinit() == null);
}

test "secure relay composes injected TLS below the one WebSocket upgrade" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const listen_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var accepted = try io.concurrent(acceptIdentityTls, .{ io, &server });

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "wss://127.0.0.1:{d}/relay",
        .{server.socket.address.getPort()},
    );
    var identity_tls = IdentityTls{};
    var tls_runtime = identity_tls.runtime();
    var provider = keyed_relay.Provider{};
    try provider.initWithTls(
        allocator,
        io,
        url,
        &tls_runtime,
    );
    try std.testing.expect(provider.keyed_resident.configuration() == provider.noise_resident.configuration());
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x73)),
    );
    const designator = identity.publicKey().toDesignator();
    var stop = std.atomic.Value(bool).init(false);
    var raw = switch (provider.keyed_resident.dialRawOutcomeCancelable(.{
        .transport = keyed_relay.transport_name,
        .designator = &designator,
    }, &stop)) {
        .connected => |connected| connected,
        .failed => |failure| return failure.classification,
    };
    const busy = provider.deinit() orelse return error.TestExpectedError;
    try std.testing.expectEqual(error.RelayCarrierBusy, busy.cause);
    try std.testing.expect(provider.keyed_resident.configuration() == provider.noise_resident.configuration());
    try std.testing.expectEqual(@as(usize, 0), identity_tls.runtime_closed);
    try std.testing.expect(raw.close() == null);
    try accepted.await(io);
    try std.testing.expect(provider.deinit() == null);
    try std.testing.expect(identity_tls.hostname_ok);
    try std.testing.expectEqual(@as(usize, 1), identity_tls.clients_closed);
    try std.testing.expectEqual(@as(usize, 1), identity_tls.runtime_closed);
}

test "secure relay provider close is failure atomic across both profiles" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var identity_tls = IdentityTls{ .refuse_runtime_close_once = true };
    var tls_runtime = identity_tls.runtime();
    var provider = keyed_relay.Provider{};
    try provider.initWithTls(
        allocator,
        threaded.io(),
        "wss://relay.example/relay",
        &tls_runtime,
    );

    const failure = provider.deinit() orelse return error.TestExpectedError;
    try std.testing.expectEqual(error.InjectedTlsRuntimeClose, failure.cause);
    try std.testing.expect(provider.keyed_resident.configuration() == provider.noise_resident.configuration());
    try std.testing.expect(provider.deinit() == null);
    try std.testing.expectEqual(@as(usize, 2), identity_tls.runtime_closed);
}

test "relay configuration equivalence covers every initializer policy fact" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const route = "ws://relay.example/relay?blue=1&green=%32";
    const register = "ws://relay.example/register?deployment=one";
    const first_key = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x41)),
    ).publicKey();
    const other_key = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x42)),
    ).publicKey();

    var baseline = try keyed_relay.Resident.initRegisteredProfile(
        allocator,
        io,
        route,
        register,
        first_key,
        .keyed,
    );
    defer std.debug.assert(baseline.deinit() == null);
    var same = try keyed_relay.Resident.initRegisteredProfile(
        allocator,
        io,
        route,
        register,
        first_key,
        .keyed,
    );
    defer std.debug.assert(same.deinit() == null);
    try std.testing.expect(baseline.sameConfiguration(&same));

    var reordered = try keyed_relay.Resident.initRegisteredProfile(
        allocator,
        io,
        "ws://relay.example/relay?green=%32&blue=1",
        register,
        first_key,
        .keyed,
    );
    defer std.debug.assert(reordered.deinit() == null);
    try std.testing.expect(!baseline.sameConfiguration(&reordered));

    var different_registration = try keyed_relay.Resident.initRegisteredProfile(
        allocator,
        io,
        route,
        "ws://relay.example/other-register",
        first_key,
        .keyed,
    );
    defer std.debug.assert(different_registration.deinit() == null);
    try std.testing.expect(!baseline.sameConfiguration(&different_registration));

    var different_identity = try keyed_relay.Resident.initRegisteredProfile(
        allocator,
        io,
        route,
        register,
        other_key,
        .keyed,
    );
    defer std.debug.assert(different_identity.deinit() == null);
    try std.testing.expect(!baseline.sameConfiguration(&different_identity));

    var dial_only = try keyed_relay.Resident.initProfile(allocator, io, route, .keyed);
    defer std.debug.assert(dial_only.deinit() == null);
    try std.testing.expect(!baseline.sameConfiguration(&dial_only));

    var other_profile = try keyed_relay.Resident.initRegisteredProfile(
        allocator,
        io,
        route,
        register,
        first_key,
        .noise,
    );
    defer std.debug.assert(other_profile.deinit() == null);
    try std.testing.expect(!baseline.sameConfiguration(&other_profile));
}

test "secure relay initialization leaves the TLS owner with its caller on refusal" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    // Configuration owns the first two allocations; refuse the carrier state
    // that would otherwise commit the TLS ownership transfer.
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 2 },
    );
    var identity_tls = IdentityTls{};
    var tls_runtime = identity_tls.runtime();
    var provider = keyed_relay.Provider{};
    try std.testing.expectError(error.OutOfMemory, provider.initWithTls(
        failing.allocator(),
        threaded.io(),
        "wss://relay.example/relay",
        &tls_runtime,
    ));
    try std.testing.expect(tls_runtime.deinitOutcome() == null);
    try std.testing.expectEqual(@as(usize, 1), identity_tls.runtime_closed);
}

fn refuseUpgrade(io: std.Io, server: *std.Io.net.Server) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(
        "HTTP/1.1 403 Forbidden\r\n" ++
            "Connection: close\r\n" ++
            "Content-Length: 0\r\n\r\n",
    );
    try writer.interface.flush();
}

test "resident DNS dial preserves the exact WebSocket refusal" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var server_future = try io.concurrent(refuseUpgrade, .{ io, &server });
    defer _ = server_future.cancel(io) catch {};

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "ws://localhost:{d}/relay",
        .{server.socket.address.getPort()},
    );
    var resident = try keyed_relay.Resident.init(allocator, io, url);
    defer _ = resident.deinit();

    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x71)),
    );
    const designator = identity.publicKey().toDesignator();
    var stop = std.atomic.Value(bool).init(false);
    const outcome = resident.dialRawOutcomeCancelable(.{
        .transport = keyed_relay.transport_name,
        .designator = &designator,
    }, &stop);
    try server_future.await(io);

    switch (outcome) {
        .connected => |connected| {
            var connection = connected;
            _ = connection.close();
            return error.TestExpectedError;
        },
        .failed => |failure| {
            try std.testing.expectEqual(error.ConnectionRefused, failure.classification);
            try std.testing.expectEqualStrings("UpgradeRefused", failure.chain.primaryName());
        },
    }
}
