//! C ABI designator grammar: locator-backed and direct host/port projection
//! share the core parser, including bracketed IPv6 and explicit refusal.

const std = @import("std");
const c = @import("c_abi");

test "host_port splits a tcp designator through the core grammar" {
    const uri = "ocapn://127.0.0.1%3A9045.tcp";
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.glowcap_locator_release(loc);

    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_host_port(loc, &host_ptr, &host_len, &port));
    try std.testing.expectEqualStrings("127.0.0.1", host_ptr.?[0..host_len]);
    try std.testing.expectEqual(@as(u16, 9045), port);
}

test "host_port unwraps a bracketed IPv6 designator" {
    const uri = "ocapn://%5B%3A%3A1%5D%3A9046.tcp";
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.glowcap_locator_release(loc);

    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_host_port(loc, &host_ptr, &host_len, &port));
    try std.testing.expectEqualStrings("::1", host_ptr.?[0..host_len]);
    try std.testing.expectEqual(@as(u16, 9046), port);
}

test "host_port refuses a designator without the grammar" {
    const uri = "ocapn://abc123nodeid.iroh";
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.glowcap_locator_release(loc);

    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        c.glowcap_locator_host_port(loc, &host_ptr, &host_len, &port),
    );
}

test "designator_host_port splits without a locator handle" {
    const designator = "127.0.0.1:9045";
    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        c.glowcap_designator_host_port(designator.ptr, designator.len, &host_ptr, &host_len, &port),
    );
    try std.testing.expectEqualStrings("127.0.0.1", host_ptr.?[0..host_len]);
    try std.testing.expectEqual(@as(u16, 9045), port);
}

test "designator_host_port unwraps a bracketed IPv6 literal" {
    const designator = "[::1]:9046";
    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        c.glowcap_designator_host_port(designator.ptr, designator.len, &host_ptr, &host_len, &port),
    );
    try std.testing.expectEqualStrings("::1", host_ptr.?[0..host_len]);
    try std.testing.expectEqual(@as(u16, 9046), port);
}

test "designator_host_port refuses a designator without the grammar" {
    const designator = "abc123nodeid";
    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        c.glowcap_designator_host_port(designator.ptr, designator.len, &host_ptr, &host_len, &port),
    );
}
