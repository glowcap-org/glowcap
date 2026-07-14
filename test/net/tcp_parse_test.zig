//! `tcp.parseDesignator` / `tcp.DialResolver.resolve` branch coverage, no
//! sockets. The locator reconnect path (`tcp.connect`) is proven end to end
//! over loopback in `tcp_test.zig`; this pins the designator-splitting itself
//! and the completion-loop dial resolve (tcp vs keyed-tcp vs unknown),
//! including the IPv6 bracket rule and the malformed cases, which a single
//! IPv4 loopback dial does not reach.

const std = @import("std");
const pancake = @import("pancake");

const tcp = pancake.net.tcp;
const crypto = pancake.foundation.crypto;

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

test "Locator.resolve: tcp uses the designator; keyed-tcp uses the hint" {
    const plain = try tcp.DialResolver.resolve("tcp", "127.0.0.1:8080", &.{});
    try std.testing.expectEqual(@as(u16, 8080), plain.getPort());

    const key = crypto.SecretKey.fromSeed([_]u8{0x5d} ** crypto.SEED_BYTES).publicKey();
    const designator = key.toDesignator();
    const keyed = try tcp.DialResolver.resolve("keyed-tcp", &designator, "127.0.0.1:9000");
    try std.testing.expectEqual(@as(u16, 9000), keyed.getPort());
}

test "Locator.resolve refuses unknown transports, empty hostports, and non-key keyed designators" {
    try std.testing.expectError(
        error.UnknownTransport,
        tcp.DialResolver.resolve("iroh", "abc", "127.0.0.1:1"),
    );
    try std.testing.expectError(
        error.InvalidAddress,
        tcp.DialResolver.resolve("tcp", "", &.{}),
    );
    try std.testing.expectError(
        error.InvalidAddress,
        tcp.DialResolver.resolve("keyed-tcp", "some-key", &.{}),
    );
    try std.testing.expectError(
        error.InvalidAddress,
        tcp.DialResolver.resolve("keyed-tcp", "not-a-canonical-key", "127.0.0.1:9000"),
    );
}
