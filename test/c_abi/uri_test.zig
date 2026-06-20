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
    const uri = "ocapn://abcd.tcp/s/my-swiss-num";
    var loc: ?*c.PancakeLocator = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_uri_parse_sturdyref(uri.ptr, uri.len, &loc));
    defer c.pancake_locator_release(loc);

    try std.testing.expectEqualStrings("tcp", try view(c.pancake_locator_transport, loc));
    try std.testing.expectEqualStrings("abcd", try view(c.pancake_locator_designator, loc));
    try std.testing.expectEqualStrings("my-swiss-num", try view(c.pancake_locator_swissnum, loc));
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
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_uri_format_peer(
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
