//! OCapN locator ⇄ URI — the out-of-band bootstrap form (OCapN `Locators`).
//!
//! A peer URI is `ocapn://<designator>.<transport>[?k=v&…]`; a sturdyref adds
//! `/s/<swiss-num>` before any query. This is how a peer address — a `tcp`
//! host/port, an `onion` service id, a self-authenticating key on any future
//! netlayer — is handed out of band to bootstrap a session, the same format the
//! reference suite and Goblins exchange.
//!
//! Parsing delegates to `std.Uri` for RFC 3986 decomposition; percent-decoding
//! uses `std.Uri.percentDecodeInPlace`. OCapN-specific splits (last-dot
//! transport, `/s/` sturdyref, query key=value pairs on percent-encoded form)
//! live here.

const std = @import("std");
const model = @import("mod.zig");

pub const Error = error{
    NotOcapnUri,
    MissingTransport,
    EmptyComponent,
    MalformedPath,
    MalformedHint,
    UnsupportedHintValue,
    UriParseError,
    OutOfMemory,
};

const scheme_str = "ocapn";
const sturdyref_path_prefix = "/s/";

pub const freePeer = model.freePeerLocator;

pub fn freeSturdyref(allocator: std.mem.Allocator, sturdyref: model.SturdyRef) void {
    model.freePeerLocator(allocator, sturdyref.peer);
    allocator.free(sturdyref.swissnum);
}

/// Get the percent-encoded string from a `std.Uri.Component`. Both variants
/// (`.raw` and `.percent_encoded`) carry the same slice type; for `.raw` the
/// string is not percent-encoded but for our purposes (splitting on structural
/// delimiters before per-field decode) we just need the bytes.
fn componentBytes(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |pe| pe,
    };
}

/// Percent-decode `s` into a fresh owned allocation. Uses `std.Uri.percentDecodeInPlace`
/// on a mutable copy.
fn percentDecodeOwned(allocator: std.mem.Allocator, s: []const u8) Error![]u8 {
    const buf = allocator.dupe(u8, s) catch return Error.OutOfMemory;
    errdefer allocator.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    if (decoded.len == buf.len) return buf;
    // Shrunk after decode; realloc to exact size.
    const exact = allocator.dupe(u8, decoded) catch return Error.OutOfMemory;
    allocator.free(buf);
    return exact;
}

fn parseUri(uri_str: []const u8) Error!std.Uri {
    return std.Uri.parse(uri_str) catch return Error.UriParseError;
}

fn splitNetloc(allocator: std.mem.Allocator, host_component: std.Uri.Component) Error!struct { transport: []u8, designator: []u8 } {
    const netloc_pe = componentBytes(host_component);
    const netloc = try percentDecodeOwned(allocator, netloc_pe);
    defer allocator.free(netloc);

    const dot = std.mem.lastIndexOfScalar(u8, netloc, '.') orelse return Error.MissingTransport;
    const designator_raw = netloc[0..dot];
    const transport_raw = netloc[dot + 1 ..];
    if (designator_raw.len == 0 or transport_raw.len == 0) return Error.EmptyComponent;

    const transport = allocator.dupe(u8, transport_raw) catch return Error.OutOfMemory;
    errdefer allocator.free(transport);
    const designator = allocator.dupe(u8, designator_raw) catch return Error.OutOfMemory;
    return .{ .transport = transport, .designator = designator };
}

/// Parse query hints. Splits on the **percent-encoded** form (so an escaped `&`
/// or `=` in a value is not treated as a delimiter), then percent-decodes each
/// key and value individually.
fn decodeHints(allocator: std.mem.Allocator, query: ?std.Uri.Component) Error!model.Hints {
    const q_component = query orelse return model.Hints.emptyFalse();
    const q = componentBytes(q_component);
    if (q.len == 0) return .{ .entries = &.{}, .empty_wire_was_false = false };

    var entries: std.ArrayList(model.HintEntry) = .empty;
    errdefer {
        for (entries.items) |entry| model.freeHintEntry(allocator, entry);
        entries.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |segment| {
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse return Error.MalformedHint;
        const name = try percentDecodeOwned(allocator, segment[0..eq]);
        errdefer allocator.free(name);
        const value = try percentDecodeOwned(allocator, segment[eq + 1 ..]);
        errdefer allocator.free(value);
        entries.append(allocator, .{ .name = name, .value = .{ .string = value } }) catch return Error.OutOfMemory;
    }

    return .{ .entries = entries.toOwnedSlice(allocator) catch return Error.OutOfMemory, .empty_wire_was_false = false };
}

pub fn parsePeer(allocator: std.mem.Allocator, uri_str: []const u8) Error!model.PeerLocator {
    const uri = try parseUri(uri_str);
    if (!std.mem.eql(u8, uri.scheme, scheme_str)) return Error.NotOcapnUri;

    const host_component = uri.host orelse return Error.MissingTransport;
    const nl = try splitNetloc(allocator, host_component);
    errdefer allocator.free(nl.transport);
    errdefer allocator.free(nl.designator);

    // A peer URI has no path; reject if present (sturdyrefs have `/s/…`).
    const path_pe = componentBytes(uri.path);
    if (path_pe.len > 0) return Error.MalformedPath;

    const hints = try decodeHints(allocator, uri.query);
    return .{ .transport = nl.transport, .designator = nl.designator, .hints = hints };
}

pub fn parseSturdyref(allocator: std.mem.Allocator, uri_str: []const u8) Error!model.SturdyRef {
    const uri = try parseUri(uri_str);
    if (!std.mem.eql(u8, uri.scheme, scheme_str)) return Error.NotOcapnUri;

    const host_component = uri.host orelse return Error.MissingTransport;
    const nl = try splitNetloc(allocator, host_component);
    errdefer allocator.free(nl.transport);
    errdefer allocator.free(nl.designator);

    const path_pe = componentBytes(uri.path);
    if (!std.mem.startsWith(u8, path_pe, sturdyref_path_prefix)) return Error.MalformedPath;
    const swiss_pe = path_pe[sturdyref_path_prefix.len..];

    const swissnum = try percentDecodeOwned(allocator, swiss_pe);
    errdefer allocator.free(swissnum);

    const hints = try decodeHints(allocator, uri.query);
    return .{
        .peer = .{ .transport = nl.transport, .designator = nl.designator, .hints = hints },
        .swissnum = swissnum,
    };
}

// ── Emit ─────────────────────────────────────────────────────────────────────

pub fn writePeer(allocator: std.mem.Allocator, locator: model.PeerLocator) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeInto(allocator, &out, locator, null);
    return out.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

pub fn writeSturdyref(allocator: std.mem.Allocator, sturdyref: model.SturdyRef) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeInto(allocator, &out, sturdyref.peer, sturdyref.swissnum);
    return out.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

fn writeInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    locator: model.PeerLocator,
    swissnum: ?[]const u8,
) Error!void {
    out.appendSlice(allocator, "ocapn://") catch return Error.OutOfMemory;
    appendPercentEncoded(allocator, out, locator.designator, safeNetloc) catch return Error.OutOfMemory;
    out.append(allocator, '.') catch return Error.OutOfMemory;
    appendPercentEncoded(allocator, out, locator.transport, safeNetloc) catch return Error.OutOfMemory;
    if (swissnum) |swiss| {
        out.appendSlice(allocator, sturdyref_path_prefix) catch return Error.OutOfMemory;
        appendPercentEncoded(allocator, out, swiss, safePath) catch return Error.OutOfMemory;
    }
    if (locator.hints.entries.len > 0) {
        out.append(allocator, '?') catch return Error.OutOfMemory;
        for (locator.hints.entries, 0..) |entry, i| {
            if (i > 0) out.append(allocator, '&') catch return Error.OutOfMemory;
            appendPercentEncoded(allocator, out, entry.name, safeQuery) catch return Error.OutOfMemory;
            out.append(allocator, '=') catch return Error.OutOfMemory;
            try writeHintValue(allocator, out, entry.value);
        }
    }
}

fn writeHintValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: model.HintValue) Error!void {
    switch (value) {
        .string => |string| appendPercentEncoded(allocator, out, string, safeQuery) catch return Error.OutOfMemory,
        .integer => |integer| {
            var buf: [24]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buf, "{d}", .{integer}) catch unreachable;
            out.appendSlice(allocator, rendered) catch return Error.OutOfMemory;
        },
        .boolean => |boolean| out.appendSlice(allocator, if (boolean) "true" else "false") catch return Error.OutOfMemory,
        .bytes => return Error.UnsupportedHintValue,
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn safeNetloc(c: u8) bool {
    return isUnreserved(c) or switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

fn safePath(c: u8) bool {
    return safeNetloc(c);
}

fn safeQuery(c: u8) bool {
    return isUnreserved(c) or switch (c) {
        '!', '$', '\'', '(', ')', '*', ',', ';' => true,
        else => false,
    };
}

fn appendPercentEncoded(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
    comptime safe: fn (u8) bool,
) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (safe(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0xf]);
        }
    }
}
