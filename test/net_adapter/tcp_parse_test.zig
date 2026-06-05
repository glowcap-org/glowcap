//! `tcp.parseDesignator` branch coverage — no sockets. The locator reconnect
//! path (`tcp.connect`) is proven end to end over loopback in `tcp_test.zig`;
//! this pins the designator-splitting itself, including the IPv6 bracket rule
//! and the malformed cases, which a single IPv4 loopback dial does not reach.

const std = @import("std");
const pancake = @import("pancake");

const tcp = pancake.net_adapter.tcp;

test "parseDesignator accepts a bracketed IPv6 designator" {
    const addr = try tcp.parseDesignator("[::1]:9000");
    try std.testing.expectEqual(@as(u16, 9000), addr.getPort());
}

test "parseDesignator accepts an IPv4 designator" {
    const addr = try tcp.parseDesignator("127.0.0.1:8080");
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
}

test "parseDesignator rejects a designator with no port colon" {
    try std.testing.expectError(error.InvalidAddress, tcp.parseDesignator("127.0.0.1"));
}

test "parseDesignator rejects a non-numeric port" {
    try std.testing.expectError(error.InvalidAddress, tcp.parseDesignator("127.0.0.1:http"));
}

test "parseDesignator rejects a non-address host" {
    try std.testing.expectError(error.InvalidAddress, tcp.parseDesignator("not-an-ip:9000"));
}
