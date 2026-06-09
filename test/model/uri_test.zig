const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const uri = model.uri;

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
    try std.testing.expect(locator.hints.empty_wire_was_false);
}

test "a designator may itself contain dots; only the last dot splits the transport" {
    const allocator = std.testing.allocator;
    const locator = try uri.parsePeer(allocator, "ocapn://a.b.c.tcp");
    defer uri.freePeer(allocator, locator);

    try std.testing.expectEqualStrings("tcp", locator.transport);
    try std.testing.expectEqualStrings("a.b.c", locator.designator);
}

test "parses a sturdyref URI: peer plus swiss-num before the query" {
    const allocator = std.testing.allocator;
    const sturdyref = try uri.parseSturdyref(
        allocator,
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

test "writeSturdyref places /s/ before the query and round-trips" {
    const allocator = std.testing.allocator;
    const original = "ocapn://abcd.onion/s/swiss?host=h";
    const sturdyref = try uri.parseSturdyref(allocator, original);
    defer uri.freeSturdyref(allocator, sturdyref);

    const emitted = try uri.writeSturdyref(allocator, sturdyref);
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings(original, emitted);
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

test "truncated percent escape passes through as literal bytes" {
    const allocator = std.testing.allocator;
    // std.Uri treats a truncated `%2` as literal bytes (lenient per RFC 3986).
    // The `%2` becomes part of the designator rather than an error.
    const locator = try uri.parsePeer(allocator, "ocapn://ab%2.tcp");
    defer uri.freePeer(allocator, locator);
    try std.testing.expectEqualStrings("tcp", locator.transport);
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
