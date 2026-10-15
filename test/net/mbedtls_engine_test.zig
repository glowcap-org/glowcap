//! The optional TLS engine compiled against the pinned Mbed TLS source.

const std = @import("std");

const mbedtls = @import("mbedtls");
const relay_tls = @import("relay_tls");

const root_pem = @embedFile("fixtures/tls_root.pem");
const server_pem = @embedFile("fixtures/tls_server.pem");

test "trust initialization refuses malformed snapshots without acquiring a runtime" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const empty = mbedtls.Runtime.initCopiedRoots(io, std.testing.allocator, "");
    try std.testing.expectEqualStrings(
        "InvalidTrustSnapshot",
        empty.failed.chain.primaryName(),
    );
    const malformed = mbedtls.Runtime.initCopiedRoots(io, std.testing.allocator, "not a certificate");
    try std.testing.expectEqualStrings(
        "InvalidTrustSnapshot",
        malformed.failed.chain.primaryName(),
    );
    try std.testing.expect(malformed.failed.detail.engine_code == null);
    const invalid_pem = mbedtls.Runtime.initCopiedRoots(
        io,
        std.testing.allocator,
        "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n",
    );
    try std.testing.expectEqualStrings(
        "InvalidTrustSnapshot",
        invalid_pem.failed.chain.primaryName(),
    );
    try std.testing.expect(invalid_pem.failed.detail.engine_code != null);
}

test "one trust owner opens clients and refuses destruction while they live" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const initialized = mbedtls.Runtime.initCopiedRoots(
        threaded.io(),
        std.testing.allocator,
        root_pem,
    );
    const ready = initialized.runtime;
    const runtime = ready.owner;
    try std.testing.expectEqual(@as(usize, 1), ready.trust.loaded);
    try std.testing.expectEqual(@as(usize, 0), ready.trust.skipped_by_engine);
    try std.testing.expect(ready.trust.first_skipped_engine_code == null);

    const invalid = runtime.open("");
    try std.testing.expectEqualStrings("InvalidTlsHostname", invalid.failed.chain.primaryName());

    var client = runtime.open("relay.example").client;
    const busy = runtime.deinitOutcome().?;
    try std.testing.expectEqualStrings("TlsRuntimeBusy", busy.primaryName());

    var ciphertext: [4096]u8 = undefined;
    const outcome = try client.step(.handshake, .{ .ciphertext_out = &ciphertext });
    try std.testing.expect(outcome.stepped.interest.read);
    try std.testing.expect(outcome.stepped.transfer.ciphertext_produced != 0);
    try std.testing.expectEqual(
        outcome.stepped.transfer.ciphertext_produced,
        client.pendingCiphertext().len,
    );
    try client.consumeCiphertext(client.pendingCiphertext().len);
    try std.testing.expect(client.deinitOutcome() == null);
    try std.testing.expect(runtime.deinitOutcome() == null);
}

test "system roots load once into an immutable runtime" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const initialized = mbedtls.Runtime.initSystemRoots(threaded.io(), std.testing.allocator);
    const ready = switch (initialized) {
        .runtime => |value| value,
        .failed => return error.SystemTrustUnavailable,
    };
    try std.testing.expect(ready.trust.loaded != 0);
    try std.testing.expectEqual(
        ready.trust.skipped_by_engine != 0,
        ready.trust.first_skipped_engine_code != null,
    );
    try std.testing.expect(ready.owner.deinitOutcome() == null);
}

test "the public relay TLS module owns TLS beneath both profiles" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var provider: relay_tls.Provider = undefined;
    const summary = switch (provider.init(
        threaded.io(),
        std.testing.allocator,
        .{ .relay_url = "ws://127.0.0.1:1/relay" },
        .{ .copied_pem = root_pem },
    )) {
        .ready => |value| value,
        .failed => |failure| {
            std.debug.print("relay TLS init failed: {s}\n", .{failure.chain().primaryName()});
            return error.UnexpectedInitializationFailure;
        },
    };
    try std.testing.expectEqual(@as(usize, 1), summary.loaded);
    const layers = provider.netlayers();
    try std.testing.expectEqual(@as(usize, 2), layers.len);
    try std.testing.expectEqualStrings("keyed-relay", layers[0].transportName());
    try std.testing.expectEqualStrings("noise-relay", layers[1].transportName());
    try std.testing.expect(provider.deinit() == null);
}

test "relay TLS equivalence compares parsed trust rather than only routes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var first: relay_tls.Provider = undefined;
    var same: relay_tls.Provider = undefined;
    var other: relay_tls.Provider = undefined;
    for ([_]struct { provider: *relay_tls.Provider, pem: []const u8 }{
        .{ .provider = &first, .pem = root_pem },
        .{ .provider = &same, .pem = root_pem },
        .{ .provider = &other, .pem = server_pem },
    }) |fixture| switch (fixture.provider.init(
        io,
        std.testing.allocator,
        .{ .relay_url = "ws://127.0.0.1:1/relay" },
        .{ .copied_pem = fixture.pem },
    )) {
        .ready => {},
        .failed => return error.UnexpectedInitializationFailure,
    };
    defer std.testing.expect(other.deinit() == null) catch unreachable;
    defer std.testing.expect(same.deinit() == null) catch unreachable;
    defer std.testing.expect(first.deinit() == null) catch unreachable;

    try std.testing.expect(first.sameConfiguration(&same));
    try std.testing.expect(!first.sameConfiguration(&other));
}
