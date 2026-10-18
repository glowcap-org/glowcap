//! `tcp.parseDesignator` / `tcp.DialResolver.resolve` branch coverage, no
//! sockets. The locator reconnect path (`tcp.connect`) is proven end to end
//! over loopback in `tcp_test.zig`. This pins the designator-splitting itself
//! and the completion-loop dial resolve (tcp vs keyed-tcp vs unknown),
//! including the IPv6 bracket rule and the malformed cases, which a single
//! IPv4 loopback dial does not reach.

const std = @import("std");
const glowcap = @import("glowcap");

const tcp = glowcap.net.tcp;
const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;

fn resolve(transport: []const u8, designator: []const u8, direct: []const u8) !std.Io.net.IpAddress {
    var entry: [1]model.HintEntry = undefined;
    return tcp.DialResolver.resolve(.{
        .transport = transport,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses(direct, &entry),
    });
}

test "parseDesignator accepts a bracketed IPv6 designator" {
    const addr = try tcp.parseDesignator("[::1]:9000");
    try std.testing.expectEqual(@as(u16, 9000), addr.getPort());
}

test "parseDesignator accepts an IPv4 designator" {
    const addr = try tcp.parseDesignator("127.0.0.1:8080");
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
}

test "parseDesignator rejects a missing port" {
    try std.testing.expectError(error.InvalidAddress, tcp.parseDesignator("127.0.0.1"));
}

test "parseDesignator rejects a non-address host" {
    try std.testing.expectError(error.InvalidAddress, tcp.parseDesignator("not-an-ip:9000"));
}

test "DialResolver.resolve: tcp uses the designator; keyed-tcp uses the hint" {
    const plain = try resolve("tcp", "127.0.0.1:8080", "");
    try std.testing.expectEqual(@as(u16, 8080), plain.getPort());

    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x5d))).publicKey();
    const designator = key.toDesignator();
    const keyed = try resolve("keyed-tcp", &designator, "127.0.0.1:9000");
    try std.testing.expectEqual(@as(u16, 9000), keyed.getPort());
}

test "profile resolution needs no transport-name dispatch" {
    const plain = try tcp.resolveProfile(
        glowcap.ocapn.model.transport.Known.tcp.metadata(),
        "127.0.0.1:8081",
        &.{},
    );
    try std.testing.expectEqual(@as(u16, 8081), plain.getPort());

    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x5f))).publicKey();
    const designator = key.toDesignator();
    const sealed = try tcp.resolveProfile(
        glowcap.ocapn.model.transport.Known.noise_tcp.metadata(),
        &designator,
        "127.0.0.1:9002",
    );
    try std.testing.expectEqual(@as(u16, 9002), sealed.getPort());
}

test "DialResolver.resolve: keyed-tcp multi-address hint dials the first entry, trimmed" {
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x5e))).publicKey();
    const designator = key.toDesignator();
    const keyed = try resolve(
        "keyed-tcp",
        &designator,
        " 127.0.0.1:9001 , 10.0.0.1:9002 ",
    );
    try std.testing.expectEqual(@as(u16, 9001), keyed.getPort());
}

test "DialResolver.resolve refuses unknown transports, empty hostports, and non-key keyed designators" {
    try std.testing.expectError(
        error.UnknownTransport,
        resolve("iroh", "abc", "127.0.0.1:1"),
    );
    try std.testing.expectError(
        error.InvalidAddress,
        resolve("tcp", "", ""),
    );
    try std.testing.expectError(
        error.InvalidAddress,
        resolve("keyed-tcp", "some-key", ""),
    );
    try std.testing.expectError(
        error.InvalidAddress,
        resolve("keyed-tcp", "not-a-canonical-key", "127.0.0.1:9000"),
    );
}
