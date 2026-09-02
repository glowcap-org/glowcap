//! C ABI OCapN locator-URI contract, proves the `glowcap_uri_*` verbs and the
//! distinct locator and sturdyref handles round-trip through the one core
//! grammar (`model.uri`), so a binding never hand-rolls a percent codec or
//! silently drops sturdyref authority.

const std = @import("std");
const glowcap = @import("glowcap");

const c = @import("c_abi");

/// Borrow a locator string field through an accessor, returning the view.
fn view(rc_fn: anytype, loc: ?*c.GlowcapLocator) ![]const u8 {
    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, rc_fn(loc, &ptr, &len));
    if (len == 0) return &.{};
    return (ptr orelse return error.NullView)[0..len];
}

fn sturdySwiss(sturdyref: ?*c.GlowcapSturdyRef) ![]const u8 {
    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_sturdyref_swissnum(sturdyref, &ptr, &len));
    return (ptr orelse return error.NullView)[0..len];
}

fn sturdyLocator(sturdyref: ?*c.GlowcapSturdyRef) !*const c.GlowcapLocatorView {
    var locator: ?*const c.GlowcapLocatorView = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_sturdyref_borrow_locator(sturdyref, &locator));
    return locator orelse error.NullView;
}

test "locator construction records the exact invalid shape" {
    c.glowcap_clear_last_error();
    var locator: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_locator_new(
        "tcp".ptr,
        "tcp".len,
        "host:1".ptr,
        "host:1".len,
        std.math.maxInt(u32),
        &locator,
    ));
    try std.testing.expect(locator == null);
    var message: [256]u8 = undefined;
    const len = @min(c.glowcap_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "InvalidHintWireForm") != null);
}

test "parse a peer URI and read its fields" {
    const uri = "ocapn://abcd.tcp";
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.glowcap_locator_release(loc);

    try std.testing.expectEqualStrings("tcp", try view(c.glowcap_locator_transport, loc));
    try std.testing.expectEqualStrings("abcd", try view(c.glowcap_locator_designator, loc));

    var count: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_hint_count(loc, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "locator constructors return every context allocation" {
    const CountingHost = @import("../support/c_abi_counting_alloc.zig").CountingHost;
    var counting: CountingHost = .{};
    const spec = counting.spec();
    var context: ?*c.GlowcapContext = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_context_new_with_allocator(&spec, &context));

    const peer_uri = "ocapn://abcd.tcp";
    var parsed_peer: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer_in(context, peer_uri.ptr, peer_uri.len, &parsed_peer));

    const sturdy_uri = "ocapn://abcd.tcp/s/d2lkZ2V0";
    var parsed_sturdy: ?*c.GlowcapSturdyRef = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_sturdyref_in(
        context,
        c.GLOWCAP_CAPTP_V1_0,
        sturdy_uri.ptr,
        sturdy_uri.len,
        &parsed_sturdy,
    ));

    var constructed: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_new_in(
        context,
        "tcp".ptr,
        "tcp".len,
        "host:1".ptr,
        "host:1".len,
        c.GLOWCAP_HINTS_MAP,
        &constructed,
    ));
    var borrowed: ?*const c.GlowcapLocatorView = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_borrow_view(constructed, &borrowed));
    var cloned: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_clone_in(context, borrowed, &cloned));

    c.glowcap_locator_release(cloned);
    c.glowcap_locator_release(constructed);
    c.glowcap_sturdyref_release(parsed_sturdy);
    c.glowcap_locator_release(parsed_peer);
    c.glowcap_context_release(context);
    try std.testing.expect(counting.balanced());
}

test "locator hint allocation refusal preserves the published view" {
    const CountingHost = @import("../support/c_abi_counting_alloc.zig").CountingHost;
    var counting: CountingHost = .{};
    const spec = counting.spec();
    var context: ?*c.GlowcapContext = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_context_new_with_allocator(&spec, &context));
    defer c.glowcap_context_release(context);

    var locator: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_new_in(
        context,
        "tcp".ptr,
        "tcp".len,
        "host:1".ptr,
        "host:1".len,
        c.GLOWCAP_HINTS_MAP,
        &locator,
    ));
    defer c.glowcap_locator_release(locator);

    var before: ?*const c.GlowcapLocatorView = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_borrow_view(locator, &before));
    try std.testing.expectEqual(@as(usize, 0), before.?.hint_count);

    counting.fail_allocations = true;
    defer counting.fail_allocations = false;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INTERNAL,
        c.glowcap_locator_add_string(locator, "mode".ptr, "mode".len, "fast".ptr, "fast".len),
    );

    var after: ?*const c.GlowcapLocatorView = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_borrow_view(locator, &after));
    try std.testing.expectEqual(before, after);
    try std.testing.expectEqual(@as(usize, 0), after.?.hint_count);
}

test "parse a peer URI with hints; look up and enumerate them" {
    const uri = "ocapn://abc123.iroh?direct-addresses=127.0.0.1:5000,%5B::1%5D:5001";
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer(uri.ptr, uri.len, &loc));
    defer c.glowcap_locator_release(loc);

    try std.testing.expectEqualStrings("iroh", try view(c.glowcap_locator_transport, loc));
    try std.testing.expectEqualStrings("abc123", try view(c.glowcap_locator_designator, loc));

    // Looked up by key, the percent-encoded brackets decode.
    const key = "direct-addresses";
    var hint: c.GlowcapLocatorHintView = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_hint(loc, key.ptr, key.len, &hint));
    try std.testing.expectEqual(c.GLOWCAP_HINT_STRING, hint.kind);
    try std.testing.expectEqualStrings("127.0.0.1:5000,[::1]:5001", hint.bytes.?[0..hint.bytes_len]);

    // Enumerated by index.
    var count: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_hint_count(loc, &count));
    try std.testing.expectEqual(@as(usize, 1), count);

    var indexed: c.GlowcapLocatorHintView = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_hint_at(loc, 0, &indexed));
    try std.testing.expectEqualStrings("direct-addresses", indexed.name.?[0..indexed.name_len]);
    try std.testing.expectEqual(c.GLOWCAP_HINT_STRING, indexed.kind);
    try std.testing.expectEqualStrings("127.0.0.1:5000,[::1]:5001", indexed.bytes.?[0..indexed.bytes_len]);

    // An absent key is a named not-found, not a malformed request.
    const missing = "no-such-hint";
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        c.glowcap_locator_hint(loc, missing.ptr, missing.len, &hint),
    );
    // Index past the end is an invalid argument.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        c.glowcap_locator_hint_at(loc, 1, &indexed),
    );
    try std.testing.expect(c.glowcap_last_error(null, 0) > 0);
}

test "parse a sturdyref URI and read its swissnum" {
    const uri = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";
    const swiss = [_]u8{
        0x79, 0x08, 0xcf, 0xe2, 0x74, 0x76, 0xf1, 0xf7,
        0xd7, 0xe5, 0xea, 0x0d, 0x08, 0xae, 0x43, 0x58,
        0x7e, 0x83, 0x4f, 0xf7, 0x7b, 0x04, 0x8a, 0x83,
        0xdf, 0xe3, 0x32, 0xe3, 0x9f, 0x42, 0x51, 0xb5,
    };
    var sturdyref: ?*c.GlowcapSturdyRef = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
        uri.ptr,
        uri.len,
        &sturdyref,
    ));
    defer c.glowcap_sturdyref_release(sturdyref);

    const locator = try sturdyLocator(sturdyref);
    try std.testing.expectEqualStrings("onion", locator.transport.?[0..locator.transport_len]);
    try std.testing.expectEqualSlices(u8, &swiss, try sturdySwiss(sturdyref));
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
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_format_peer(
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
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_peer(rendered.ptr, rendered.len, &loc));
    defer c.glowcap_locator_release(loc);
    try std.testing.expectEqualStrings("iroh", try view(c.glowcap_locator_transport, loc));
    try std.testing.expectEqualStrings("node-id-abc", try view(c.glowcap_locator_designator, loc));

    const key = "direct-addresses";
    var hint: c.GlowcapLocatorHintView = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_locator_hint(loc, key.ptr, key.len, &hint));
    try std.testing.expectEqual(c.GLOWCAP_HINT_STRING, hint.kind);
    try std.testing.expectEqualStrings("127.0.0.1:5000", hint.bytes.?[0..hint.bytes_len]);
}

test "format a sturdyref URI round-trips through parse" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    const swissnum = "swiss-42";

    var buf: [256]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
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

    var sturdyref: ?*c.GlowcapSturdyRef = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
        rendered.ptr,
        rendered.len,
        &sturdyref,
    ));
    defer c.glowcap_sturdyref_release(sturdyref);
    const locator = try sturdyLocator(sturdyref);
    try std.testing.expectEqualStrings("tcp", locator.transport.?[0..locator.transport_len]);
    try std.testing.expectEqualStrings("127.0.0.1:9000", locator.designator.?[0..locator.designator_len]);
    try std.testing.expectEqualStrings("swiss-42", try sturdySwiss(sturdyref));
}

test "sturdyref formatting and parsing preserve the selected profile" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    const swissnum = "glowcap-durable-1-27c49cd0df0675f8501cd6920d8404e1";

    var buf: [256]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_NEXT,
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
    try std.testing.expectEqualStrings(
        "ocapn://127.0.0.1%3A9000.tcp/s/glowcap-durable-1-27c49cd0df0675f8501cd6920d8404e1",
        rendered,
    );

    var sturdyref: ?*c.GlowcapSturdyRef = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_parse_sturdyref(
        c.GLOWCAP_CAPTP_NEXT,
        rendered.ptr,
        rendered.len,
        &sturdyref,
    ));
    defer c.glowcap_sturdyref_release(sturdyref);
    try std.testing.expectEqualStrings(swissnum, try sturdySwiss(sturdyref));

    var refused: ?*c.GlowcapSturdyRef = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_uri_parse_sturdyref(
        99,
        rendered.ptr,
        rendered.len,
        &refused,
    ));
    try std.testing.expect(refused == null);
}

test "format reports the needed length when the buffer is too small" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    var tiny: [4]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_BUFFER_TOO_SMALL, c.glowcap_uri_format_peer(
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

test "format refuses an excessive hint count before touching hint arrays" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    const swissnum = "swiss-42";
    const excessive = glowcap.ocapn.model.max_locator_hint_count + 1;
    var out_len: usize = 0;

    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        null,
        null,
        null,
        excessive,
        null,
        0,
        &out_len,
    ));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
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
        excessive,
        null,
        0,
        &out_len,
    ));
}

test "format probes report the needed URI length without an output buffer" {
    const transport = "tcp";
    const designator = "127.0.0.1:9000";
    const swissnum = "swiss-42";
    const expected_peer = "ocapn://127.0.0.1%3A9000.tcp";
    const expected_sturdyref = "ocapn://127.0.0.1%3A9000.tcp/s/c3dpc3MtNDI";

    var peer_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_BUFFER_TOO_SMALL, c.glowcap_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        null,
        null,
        null,
        0,
        null,
        0,
        &peer_len,
    ));
    try std.testing.expectEqual(expected_peer.len, peer_len);

    var peer_buf: [expected_peer.len]u8 = undefined;
    var exact_peer_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        null,
        null,
        null,
        0,
        &peer_buf,
        peer_buf.len,
        &exact_peer_len,
    ));
    try std.testing.expectEqual(expected_peer.len, exact_peer_len);
    try std.testing.expectEqualStrings(expected_peer, peer_buf[0..]);

    var ignored_peer_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        null,
        null,
        null,
        0,
        null,
        1,
        &ignored_peer_len,
    ));
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_uri_format_peer(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        null,
        null,
        null,
        0,
        null,
        0,
        null,
    ));

    var sturdyref_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_BUFFER_TOO_SMALL, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
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
        null,
        0,
        &sturdyref_len,
    ));
    try std.testing.expectEqual(expected_sturdyref.len, sturdyref_len);

    var sturdyref_buf: [expected_sturdyref.len]u8 = undefined;
    var exact_sturdyref_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
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
        &sturdyref_buf,
        sturdyref_buf.len,
        &exact_sturdyref_len,
    ));
    try std.testing.expectEqual(expected_sturdyref.len, exact_sturdyref_len);
    try std.testing.expectEqualStrings(expected_sturdyref, sturdyref_buf[0..]);

    var ignored_sturdyref_len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
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
        null,
        1,
        &ignored_sturdyref_len,
    ));
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_uri_format_sturdyref(
        c.GLOWCAP_CAPTP_V1_0,
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
        null,
        0,
        null,
    ));
}

test "a malformed URI is a named invalid argument, not a crash" {
    const not_a_uri = "https://example.com/";
    var loc: ?*c.GlowcapLocator = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        c.glowcap_uri_parse_peer(not_a_uri.ptr, not_a_uri.len, &loc),
    );
    try std.testing.expect(loc == null);
}

test "parse rejects null pointers" {
    var loc: ?*c.GlowcapLocator = null;
    const malformed = "https://example.invalid/";
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        c.glowcap_uri_parse_peer(malformed.ptr, malformed.len, &loc),
    );
    try std.testing.expect(c.glowcap_last_error(null, 0) > 0);

    // This refusal has no richer cause. It must not inherit the malformed
    // URI's diagnostic merely because both calls used this thread.
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_uri_parse_peer(null, 0, &loc));
    try std.testing.expectEqual(@as(usize, 0), c.glowcap_last_error(null, 0));
    const uri = "ocapn://x.tcp";
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_uri_parse_peer(uri.ptr, uri.len, null));
    // Releasing null is a no-op.
    c.glowcap_locator_release(null);
}
