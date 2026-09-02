const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const uri = model.uri;

const goblins_sturdyref_uri = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";
const goblins_swiss = [_]u8{
    0x79, 0x08, 0xcf, 0xe2, 0x74, 0x76, 0xf1, 0xf7,
    0xd7, 0xe5, 0xea, 0x0d, 0x08, 0xae, 0x43, 0x58,
    0x7e, 0x83, 0x4f, 0xf7, 0x7b, 0x04, 0x8a, 0x83,
    0xdf, 0xe3, 0x32, 0xe3, 0x9f, 0x42, 0x51, 0xb5,
};

test "parses the conformance peer URI: designator, transport, and hints" {
    const allocator = std.testing.allocator;
    const locator = try uri.parsePeer(
        allocator,
        "ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22055",
    );
    defer uri.freePeer(allocator, locator);

    // The transport is the suffix after the LAST dot; the base64 `+` in the
    // designator survives raw (no `+`-means-space form).
    try std.testing.expectEqualStrings("tcp-testing-only", locator.transport);
    try std.testing.expectEqualStrings("JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ", locator.designator);
    try std.testing.expectEqual(@as(usize, 2), locator.hints.entries.len);
    try std.testing.expectEqualStrings("host", locator.hints.entries[0].name);
    try std.testing.expectEqualStrings("127.0.0.1", locator.hints.entries[0].value.string);
    try std.testing.expectEqualStrings("port", locator.hints.entries[1].name);
    try std.testing.expectEqualStrings("22055", locator.hints.entries[1].value.string);
}

test "parses a hintless peer URI as hints-absent" {
    const allocator = std.testing.allocator;
    const locator = try uri.parsePeer(allocator, "ocapn://abcd.onion");
    defer uri.freePeer(allocator, locator);

    try std.testing.expectEqualStrings("onion", locator.transport);
    try std.testing.expectEqualStrings("abcd", locator.designator);
    try std.testing.expectEqual(@as(usize, 0), locator.hints.entries.len);
    // No query → `#f` hints on the wire, not an empty map.
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, locator.hints.wire_form);
}

test "a designator may itself contain dots; only the last dot splits the transport" {
    const allocator = std.testing.allocator;
    const locator = try uri.parsePeer(allocator, "ocapn://a.b.c.tcp");
    defer uri.freePeer(allocator, locator);

    try std.testing.expectEqualStrings("tcp", locator.transport);
    try std.testing.expectEqualStrings("a.b.c", locator.designator);
}

test "next parses a sturdyref URI as raw swiss bytes before the query" {
    const allocator = std.testing.allocator;
    const sturdyref = try uri.parseSturdyrefForProfile(
        allocator,
        .next,
        "ocapn://abcd.tcp-testing-only/s/my-swiss-num?host=127.0.0.1",
    );
    defer uri.freeSturdyref(allocator, sturdyref);

    try std.testing.expectEqualStrings("tcp-testing-only", sturdyref.peer.transport);
    try std.testing.expectEqualStrings("abcd", sturdyref.peer.designator);
    try std.testing.expectEqualStrings("my-swiss-num", sturdyref.swissnum);
    try std.testing.expectEqual(@as(usize, 1), sturdyref.peer.hints.entries.len);
    try std.testing.expectEqualStrings("host", sturdyref.peer.hints.entries[0].name);
}

test "percent escapes decode, and a structural slash round-trips through %2F" {
    const allocator = std.testing.allocator;
    // A designator carrying a `/` must arrive escaped, or it would split the path.
    const locator = try uri.parsePeer(allocator, "ocapn://ab%2Fcd.tcp");
    defer uri.freePeer(allocator, locator);
    try std.testing.expectEqualStrings("ab/cd", locator.designator);

    const emitted = try uri.writePeer(allocator, locator);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings("ocapn://ab%2Fcd.tcp", emitted);
}

test "writePeer round-trips a hinted locator through parsePeer" {
    const allocator = std.testing.allocator;
    const original = "ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22055";
    const locator = try uri.parsePeer(allocator, original);
    defer uri.freePeer(allocator, locator);

    const emitted = try uri.writePeer(allocator, locator);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings(original, emitted);
}

test "writePeer round-trips an encoded OCapN authority beyond the DNS hostname limit" {
    const allocator = std.testing.allocator;
    var designator: [124]u8 = undefined;
    @memset(&designator, 0xff);
    const original: model.PeerLocator = .{
        .transport = "tcp",
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    };

    const emitted = try uri.writePeer(allocator, original);
    defer allocator.free(emitted);
    try std.testing.expect(emitted.len > std.Io.net.HostName.max_len);

    const reparsed = try uri.parsePeer(allocator, emitted);
    defer uri.freePeer(allocator, reparsed);
    try std.testing.expectEqualStrings(original.transport, reparsed.transport);
    try std.testing.expectEqualSlices(u8, original.designator, reparsed.designator);
}

test "next writeSturdyref places raw swiss bytes before the query and round-trips" {
    const allocator = std.testing.allocator;
    const original = "ocapn://abcd.onion/s/swiss%2F%00?host=h";
    const sturdyref = try uri.parseSturdyrefForProfile(allocator, .next, original);
    defer uri.freeSturdyref(allocator, sturdyref);
    try std.testing.expectEqualStrings("swiss/\x00", sturdyref.swissnum);

    const emitted = try uri.writeSturdyrefForProfile(allocator, .next, sturdyref);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings(original, emitted);
}

test "default sturdyref parser decodes the exact Goblins unpadded base64url vector" {
    const allocator = std.testing.allocator;
    const sturdyref = try uri.parseSturdyref(allocator, goblins_sturdyref_uri);
    defer uri.freeSturdyref(allocator, sturdyref);

    try std.testing.expectEqualStrings("onion", sturdyref.peer.transport);
    try std.testing.expectEqualSlices(u8, &goblins_swiss, sturdyref.swissnum);
}

test "default sturdyref renderer emits the exact Goblins unpadded base64url vector" {
    const allocator = std.testing.allocator;
    const rendered = try uri.writeSturdyref(allocator, .{
        .peer = .{
            .transport = "onion",
            .designator = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd",
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = &goblins_swiss,
    });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(goblins_sturdyref_uri, rendered);
}

test "v1 sturdyref parser rejects padded and non-url-safe base64" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        uri.Error.InvalidSwissNumber,
        uri.parseSturdyrefForProfile(allocator, .v1_0, "ocapn://abcd.onion/s/YQ=="),
    );
    try std.testing.expectError(
        uri.Error.InvalidSwissNumber,
        uri.parseSturdyrefForProfile(allocator, .v1_0, "ocapn://abcd.onion/s/YQ+/"),
    );
}

test "emits integer and boolean hint values as their URI string form" {
    const allocator = std.testing.allocator;
    const entries = [_]model.HintEntry{
        .{ .name = "port", .value = .{ .integer = 22055 } },
        .{ .name = "secure", .value = .{ .boolean = true } },
    };
    const locator: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "abcd",
        .hints = .{ .entries = &entries },
    };
    const emitted = try uri.writePeer(allocator, locator);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings("ocapn://abcd.tcp?port=22055&secure=true", emitted);
}

test "a query value containing & and = is escaped so it cannot be misparsed" {
    const allocator = std.testing.allocator;
    const entries = [_]model.HintEntry{
        .{ .name = "k", .value = .{ .string = "a&b=c" } },
    };
    const locator: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "abcd",
        .hints = .{ .entries = &entries },
    };
    const emitted = try uri.writePeer(allocator, locator);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings("ocapn://abcd.tcp?k=a%26b%3Dc", emitted);

    const reparsed = try uri.parsePeer(allocator, emitted);
    defer uri.freePeer(allocator, reparsed);
    try std.testing.expectEqualStrings("a&b=c", reparsed.hints.entries[0].value.string);
}

test "rejects a non-ocapn scheme" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(uri.Error.NotOcapnUri, uri.parsePeer(allocator, "https://example.com"));
}

test "rejects an authority with no transport suffix" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(uri.Error.MissingTransport, uri.parsePeer(allocator, "ocapn://no-dot-here"));
}

test "an escaped dot is data, never the transport delimiter" {
    const allocator = std.testing.allocator;
    // The netloc splits on its percent-encoded form. `%2E` decodes to `.`, but
    // it must not become a structural delimiter: a netloc whose only dot is
    // escaped has no transport suffix at all.
    try std.testing.expectError(uri.Error.MissingTransport, uri.parsePeer(allocator, "ocapn://ab%2Etcp"));

    // An escaped dot inside the designator survives as data; only the literal
    // dot splits the transport.
    const locator = try uri.parsePeer(allocator, "ocapn://a%2Eb.tcp");
    defer uri.freePeer(allocator, locator);
    try std.testing.expectEqualStrings("a.b", locator.designator);
    try std.testing.expectEqualStrings("tcp", locator.transport);
}

test "a transport symbol cannot contain a dot" {
    const allocator = std.testing.allocator;
    const original: model.PeerLocator = .{ .transport = "a.b", .designator = "x.y", .hints = model.Hints.emptyFalse() };
    try std.testing.expectError(uri.Error.InvalidLocator, uri.writePeer(allocator, original));
    try std.testing.expectError(uri.Error.InvalidLocator, uri.parsePeer(allocator, "ocapn://x.y.a%2Eb"));
}

test "malformed percent escapes are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(uri.Error.MalformedPercentEncoding, uri.parsePeer(allocator, "ocapn://ab%2.tcp"));
    try std.testing.expectError(uri.Error.MalformedPercentEncoding, uri.parsePeer(allocator, "ocapn://ab%GG.tcp"));
}

test "userinfo port and fragment components are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(uri.Error.UnsupportedUriComponent, uri.parsePeer(allocator, "ocapn://user@abcd.tcp"));
    try std.testing.expectError(uri.Error.UnsupportedUriComponent, uri.parsePeer(allocator, "ocapn://abcd.tcp:80"));
    try std.testing.expectError(uri.Error.UnsupportedUriComponent, uri.parsePeer(allocator, "ocapn://abcd.tcp#fragment"));
}

test "peer URI refuses excess hints before materializing another entry" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "ocapn://127.0.0.1%3A9000.tcp?");
    for (0..model.max_locator_hint_count + 1) |index| {
        if (index != 0) try text.append(allocator, '&');
        var entry: [32]u8 = undefined;
        try text.appendSlice(allocator, try std.fmt.bufPrint(&entry, "h{d}=v", .{index}));
    }
    try std.testing.expectError(uri.Error.InvalidLocator, uri.parsePeer(allocator, text.items));
}

test "parsePeer on a sturdyref-shaped path rejects the unknown path" {
    const allocator = std.testing.allocator;
    // A peer URI has no path; a `/x/` that is not the sturdyref marker is malformed.
    try std.testing.expectError(uri.Error.MalformedPath, uri.parsePeer(allocator, "ocapn://abcd.tcp/x/foo"));
}

test "a byte-array hint value has no URI form" {
    const allocator = std.testing.allocator;
    const entries = [_]model.HintEntry{
        .{ .name = "blob", .value = .{ .bytes = "raw" } },
    };
    const locator: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "abcd",
        .hints = .{ .entries = &entries },
    };
    try std.testing.expectError(uri.Error.UnsupportedHintValue, uri.writePeer(allocator, locator));
}

test "splitHostPort splits an IPv4 host:port designator" {
    const split = try uri.splitHostPort("127.0.0.1:8080");
    try std.testing.expectEqualStrings("127.0.0.1", split.host);
    try std.testing.expectEqual(@as(u16, 8080), split.port);
}

test "splitHostPort unwraps a bracketed IPv6 literal" {
    const split = try uri.splitHostPort("[::1]:9000");
    try std.testing.expectEqualStrings("::1", split.host);
    try std.testing.expectEqual(@as(u16, 9000), split.port);
}

test "splitHostPort keeps a hostname intact" {
    const split = try uri.splitHostPort("example.test:1234");
    try std.testing.expectEqualStrings("example.test", split.host);
}

test "splitHostPort rejects a designator with no port colon" {
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort("127.0.0.1"));
}

test "splitHostPort rejects a non-numeric port" {
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort("host:http"));
}

test "splitHostPort rejects a port past u16" {
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort("host:70000"));
}

test "splitHostPort rejects an empty host" {
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort(":9000"));
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort("[]:9000"));
}

test "splitHostPort rejects non-digit port spellings" {
    // `parseInt` alone would admit these; a wire grammar must not.
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort("host:+80"));
    try std.testing.expectError(uri.Error.InvalidHostPort, uri.splitHostPort("host:9_000"));
}
