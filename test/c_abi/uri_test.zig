//! C ABI OCapN locator-URI contract, proves the `pancake_uri_*` verbs and the
//! `pancake_locator_*` accessors round-trip a peer and a sturdyref through the
//! one core grammar (`model.uri`), so a binding never hand-rolls a percent
//! codec. Parse yields one owned `PancakeLocator`; format renders it back;
//! hints enumerate; a malformed URI is a named invalid argument.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

/// Borrow a locator string field through an accessor, returning the view.
fn view(rc_fn: anytype, loc: ?*c.PancakeLocator) ![]const u8 {
    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, rc_fn(loc, &ptr, &len));
    if (len == 0) return &.{};
    return (ptr orelse return error.NullView)[0..len];
}

test "parse a peer URI and read its fields" {
    const uri = "ocapn://abcd.tcp";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    try std.testing.expectEqualStrings("tcp", try view(c.pancake_locator_transport, loc));
    try std.testing.expectEqualStrings("abcd", try view(c.pancake_locator_designator, loc));
    // A peer URI carries no swissnum: zero-length view.
    try std.testing.expectEqualStrings("", try view(c.pancake_locator_swissnum, loc));

    var count: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_hint_count(loc, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "parse a peer URI with hints; look up and enumerate them" {
    const uri = "ocapn://abc123.iroh?direct-addresses=127.0.0.1:5000,%5B::1%5D:5001";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    try std.testing.expectEqualStrings("iroh", try view(c.pancake_locator_transport, loc));
    try std.testing.expectEqualStrings("abc123", try view(c.pancake_locator_designator, loc));

    // Looked up by key, the percent-encoded brackets decode.
    const key = "direct-addresses";
    var vptr: ?[*]const u8 = null;
    var vlen: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_hint(loc, key.ptr, key.len, &vptr, &vlen));
    try std.testing.expectEqualStrings("127.0.0.1:5000,[::1]:5001", vptr.?[0..vlen]);

    // Enumerated by index.
    var count: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_hint_count(loc, &count));
    try std.testing.expectEqual(@as(usize, 1), count);

    var kptr: ?[*]const u8 = null;
    var klen: usize = 0;
    var avptr: ?[*]const u8 = null;
    var avlen: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_hint_at(loc, 0, &kptr, &klen, &avptr, &avlen));
    try std.testing.expectEqualStrings("direct-addresses", kptr.?[0..klen]);
    try std.testing.expectEqualStrings("127.0.0.1:5000,[::1]:5001", avptr.?[0..avlen]);

    // An absent key is a named not-found, not a malformed request.
    const missing = "no-such-hint";
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        c.pancake_locator_hint(loc, missing.ptr, missing.len, &vptr, &vlen),
    );
    // Index past the end is an invalid argument.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_locator_hint_at(loc, 1, &kptr, &klen, &avptr, &avlen),
    );
}

test "parse a sturdyref URI and read its swissnum" {
    const uri = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";
    const swiss = [_]u8{
        0x79, 0x08, 0xcf, 0xe2, 0x74, 0x76, 0xf1, 0xf7,
        0xd7, 0xe5, 0xea, 0x0d, 0x08, 0xae, 0x43, 0x58,
        0x7e, 0x83, 0x4f, 0xf7, 0x7b, 0x04, 0x8a, 0x83,
        0xdf, 0xe3, 0x32, 0xe3, 0x9f, 0x42, 0x51, 0xb5,
    };
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_sturdyref(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    try std.testing.expectEqualStrings("onion", try view(c.pancake_locator_transport, loc));
    try std.testing.expectEqualSlices(u8, &swiss, try view(c.pancake_locator_swissnum, loc));
}

test "format a peer URI with a hint, then parse it back" {
    const transport = "iroh";
    const designator = "node-id-abc";
    const hint_keys = [_]?[*]const u8{"direct-addresses".ptr};
    const hint_key_lens = [_]usize{"direct-addresses".len};
    const hint_vals = [_]?[*]const u8{"127.0.0.1:5000".ptr};
    const hint_val_lens = [_]usize{"127.0.0.1:5000".len};

    var buf: [256]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        &hint_keys,
        &hint_key_lens,
        &hint_vals,
        &hint_val_lens,
        1,
        &buf,
        buf.len,
        &out_len,
    ));
    const rendered = buf[0..out_len];

    // Round-trips: parsing the rendered URI recovers every field.
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_peer(rendered.ptr, rendered.len, &loc));
    defer c.pancake_locator_release(loc);
    try std.testing.expectEqualStrings("iroh", try view(c.pancake_locator_transport, loc));
    try std.testing.expectEqualStrings("node-id-abc", try view(c.pancake_locator_designator, loc));

    const key = "direct-addresses";
    var vptr: ?[*]const u8 = null;
    var vlen: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_hint(loc, key.ptr, key.len, &vptr, &vlen));
    try std.testing.expectEqualStrings("127.0.0.1:5000", vptr.?[0..vlen]);
}

test "format a sturdyref URI round-trips through parse" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    const swissnum = "swiss-42";

    var buf: [256]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_format_sturdyref(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        swissnum.ptr,
        swissnum.len,
        null,
        null,
        null,
        null,
        0,
        &buf,
        buf.len,
        &out_len,
    ));
    const rendered = buf[0..out_len];
    try std.testing.expectEqualStrings("ocapn://127.0.0.1%3A9000.tcp/s/c3dpc3MtNDI", rendered);

    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_sturdyref(rendered.ptr, rendered.len, &loc));
    defer c.pancake_locator_release(loc);
    try std.testing.expectEqualStrings("tcp", try view(c.pancake_locator_transport, loc));
    try std.testing.expectEqualStrings("127.0.0.1:9000", try view(c.pancake_locator_designator, loc));
    try std.testing.expectEqualStrings("swiss-42", try view(c.pancake_locator_swissnum, loc));
}

test "format reports the needed length when the buffer is too small" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    var tiny: [4]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_BUFFER_TOO_SMALL, c.pancake_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        null,
        null,
        null,
        0,
        &tiny,
        tiny.len,
        &out_len,
    ));
    // The full URI length is still reported, so a caller can size and retry.
    try std.testing.expect(out_len > tiny.len);
}

test "a malformed URI is a named invalid argument, not a crash" {
    const not_a_uri = "https://example.com/";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_uri_parse_peer(not_a_uri.ptr, not_a_uri.len, &loc),
    );
    try std.testing.expect(loc == null);
}

test "parse rejects null pointers" {
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_uri_parse_peer(null, 0, &loc));
    const uri = "ocapn://x.tcp";
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_uri_parse_peer(uri.ptr, uri.len, null));
    // Releasing null is a no-op.
    c.pancake_locator_release(null);
}

test "host_port splits a tcp designator through the core grammar" {
    const uri = "ocapn://127.0.0.1%3A9045.tcp";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_host_port(loc, &host_ptr, &host_len, &port));
    try std.testing.expectEqualStrings("127.0.0.1", host_ptr.?[0..host_len]);
    try std.testing.expectEqual(@as(u16, 9045), port);
}

test "host_port unwraps a bracketed IPv6 designator" {
    const uri = "ocapn://%5B%3A%3A1%5D%3A9046.tcp";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_locator_host_port(loc, &host_ptr, &host_len, &port));
    try std.testing.expectEqualStrings("::1", host_ptr.?[0..host_len]);
    try std.testing.expectEqual(@as(u16, 9046), port);
}

test "host_port refuses a designator without the grammar" {
    const uri = "ocapn://abc123nodeid.iroh";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_locator_host_port(loc, &host_ptr, &host_len, &port),
    );
}

test "designator_host_port splits without a locator handle" {
    const designator = "127.0.0.1:9045";
    var host_ptr: ?[*]const u8 = null;
    var host_len: usize = 0;
    var port: u16 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_designator_host_port(designator.ptr, designator.len, &host_ptr, &host_len, &port),
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
        c.PANCAKE_OK,
        c.pancake_designator_host_port(designator.ptr, designator.len, &host_ptr, &host_len, &port),
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
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_designator_host_port(designator.ptr, designator.len, &host_ptr, &host_len, &port),
    );
}
