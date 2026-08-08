//! Turning an OCapN locator into an `ocapn://` URI and back — the out-of-band
//! bootstrap form the OCapN `Locators` spec defines.
//!
//! A peer URI is `ocapn://<designator>.<transport>[?k=v&…]`; a sturdyref adds
//! `/s/<swiss-num>` before any query. This is how a peer address — a `tcp`
//! host/port, an `onion` service id, a self-authenticating key on any
//! netlayer — is handed out of band to bootstrap a session, the same format the
//! reference suite and Goblins exchange.
//!
//! Parsing delegates to `std.Uri` for RFC 3986 decomposition; percent-decoding
//! uses `std.Uri.percentDecodeInPlace`. OCapN-specific splits (last-dot
//! transport, `/s/` sturdyref, query key=value pairs on percent-encoded form)
//! live here. A V1.0 sturdyref's swiss number is unpadded base64url, matching
//! Goblins; `next` keeps the current draft's RFC 3986-escaped raw string.
//!
//! Query hints carry no wire type system, so parsing always yields `string`
//! hint values. Writing a typed `HintValue` is a write-side convenience: an
//! integer or boolean renders as its text and comes back from a parse as a
//! string, and a `bytes` value is refused on write.

const std = @import("std");
const model = @import("mod.zig");

pub const Error = error{
    NotOcapnUri,
    MissingTransport,
    EmptyComponent,
    MalformedPath,
    InvalidSwissNumber,
    MalformedHint,
    UnsupportedHintValue,
    UriParseError,
    InvalidHostPort,
    /// `tcpConnectHostPort` was asked for a transport it does not resolve
    /// (`tcp` and `keyed-tcp` only).
    UnknownTransport,
    /// A `keyed-tcp` dial has no usable `direct-addresses` hint entry.
    MissingDirectAddressesHint,
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
    const buf = try allocator.dupe(u8, s);
    errdefer allocator.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    if (decoded.len == buf.len) return buf;
    // Shrunk after decode; realloc to exact size.
    const exact = try allocator.dupe(u8, decoded);
    allocator.free(buf);
    return exact;
}

fn parseUri(uri_str: []const u8) Error!std.Uri {
    return std.Uri.parse(uri_str) catch return Error.UriParseError;
}

/// Split the netloc into designator and transport on the last dot. The split
/// happens on the **percent-encoded** form (so an escaped `.` in the designator
/// is data, not a structural delimiter), then each side percent-decodes
/// individually, the same discipline as `decodeHints`.
fn splitNetloc(allocator: std.mem.Allocator, host_component: std.Uri.Component) Error!struct { transport: []u8, designator: []u8 } {
    const netloc_pe = componentBytes(host_component);

    const dot = std.mem.lastIndexOfScalar(u8, netloc_pe, '.') orelse return Error.MissingTransport;
    const designator_pe = netloc_pe[0..dot];
    const transport_pe = netloc_pe[dot + 1 ..];
    if (designator_pe.len == 0 or transport_pe.len == 0) return Error.EmptyComponent;

    const transport = try percentDecodeOwned(allocator, transport_pe);
    errdefer allocator.free(transport);
    const designator = try percentDecodeOwned(allocator, designator_pe);
    return .{ .transport = transport, .designator = designator };
}

/// Parse query hints. Splits on the **percent-encoded** form (so an escaped `&`
/// or `=` in a value is not treated as a delimiter), then percent-decodes each
/// key and value individually.
fn decodeHints(allocator: std.mem.Allocator, query: ?std.Uri.Component) Error!model.Hints {
    const q_component = query orelse return model.Hints.emptyFalse();
    const q = componentBytes(q_component);
    if (q.len == 0) return .{ .entries = &.{}, .wire_form = .map };

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
        try entries.append(allocator, .{ .name = name, .value = .{ .string = value } });
    }

    return .{ .entries = try entries.toOwnedSlice(allocator), .wire_form = .map };
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

/// Parse the baseline Goblins-compatible sturdyref URI form.
pub fn parseSturdyref(allocator: std.mem.Allocator, uri_str: []const u8) Error!model.SturdyRef {
    return parseSturdyrefForProfile(allocator, .v1_0, uri_str);
}

pub fn parseSturdyrefForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    uri_str: []const u8,
) Error!model.SturdyRef {
    const uri = try parseUri(uri_str);
    if (!std.mem.eql(u8, uri.scheme, scheme_str)) return Error.NotOcapnUri;

    const host_component = uri.host orelse return Error.MissingTransport;
    const nl = try splitNetloc(allocator, host_component);
    errdefer allocator.free(nl.transport);
    errdefer allocator.free(nl.designator);

    const path_pe = componentBytes(uri.path);
    if (!std.mem.startsWith(u8, path_pe, sturdyref_path_prefix)) return Error.MalformedPath;
    const swiss_pe = path_pe[sturdyref_path_prefix.len..];

    const swissnum = try decodeSwissNumber(allocator, profile, swiss_pe);
    errdefer allocator.free(swissnum);

    const hints = try decodeHints(allocator, uri.query);
    return .{
        .peer = .{ .transport = nl.transport, .designator = nl.designator, .hints = hints },
        .swissnum = swissnum,
    };
}

fn decodeSwissNumber(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    swiss_pe: []const u8,
) Error![]u8 {
    if (profile == .next) return percentDecodeOwned(allocator, swiss_pe);

    // Base64url itself needs no escaping, but URI parsing happens before the
    // profile grammar, so accept an RFC 3986 spelling of an alphabet byte.
    var encoded_owned: ?[]u8 = null;
    defer if (encoded_owned) |encoded| allocator.free(encoded);
    const encoded = if (std.mem.indexOfScalar(u8, swiss_pe, '%') != null) blk: {
        encoded_owned = try percentDecodeOwned(allocator, swiss_pe);
        break :blk encoded_owned.?;
    } else swiss_pe;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return Error.InvalidSwissNumber;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return Error.InvalidSwissNumber;
    return decoded;
}

/// A `host:port` designator split into its two halves. `host` borrows the
/// designator bytes (brackets already stripped from an IPv6 literal).
pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

/// Split a `host:port` designator — the address grammar a socket transport's
/// locator designator carries. The split is on the **last** colon, so a
/// bracketed IPv6 literal such as `[::1]:9000` keeps its address intact; the
/// brackets are stripped from the returned host, which is what a host resolver
/// expects. The port must be a decimal `u16` and the host must be non-empty.
/// This is the one definition of that grammar: the native TCP netlayer and the
/// C ABI (`pancake_designator_host_port` / `pancake_locator_host_port`) both split
/// through it, so a consumer dialing with its own sockets validates the same
/// way the native dialer does.
/// The first entry of a comma-separated `direct-addresses` hint, trimmed.
/// A `keyed-tcp` hint carries the address(es) to dial; an implementation that
/// published several picks the first. Returns a sub-slice of `hint` (empty when
/// the first entry is empty or the hint is only separators).
pub fn firstDirectAddress(hint: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, hint, ',') orelse hint.len;
    return std.mem.trim(u8, hint[0..comma], " \t");
}

pub fn splitHostPort(designator: []const u8) Error!HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, designator, ':') orelse return Error.InvalidHostPort;
    var host = designator[0..colon];
    const port_text = designator[colon + 1 ..];
    // Plain ASCII digits only: `parseInt` alone would admit Zig integer-literal
    // spellings (`+80`, `9_000`) into a wire grammar.
    if (port_text.len == 0) return Error.InvalidHostPort;
    for (port_text) |ch| {
        if (ch < '0' or ch > '9') return Error.InvalidHostPort;
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return Error.InvalidHostPort;
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    if (host.len == 0) return Error.InvalidHostPort;
    return .{ .host = host, .port = port };
}

/// Resolve the TCP-family connect `host:port` from locator pieces. This is the
/// one admission for `tcp` / `keyed-tcp` hostport selection: `planDial` and
/// `tcp.DialResolver` both call it so the first-address / split grammar cannot
/// drift. Key-shape checks stay with the callers that own crypto
/// (`PeerKey.fromDesignator`). Views borrow `designator` or `hint`.
pub fn tcpConnectHostPort(
    transport: []const u8,
    designator: []const u8,
    direct_addresses_hint: []const u8,
) Error!HostPort {
    if (std.mem.eql(u8, transport, model.transport.tcp)) {
        return splitHostPort(designator);
    }
    if (std.mem.eql(u8, transport, model.transport.keyed_tcp)) {
        if (direct_addresses_hint.len == 0) return Error.MissingDirectAddressesHint;
        const first = firstDirectAddress(direct_addresses_hint);
        if (first.len == 0) return Error.MissingDirectAddressesHint;
        return splitHostPort(first);
    }
    return Error.UnknownTransport;
}

// ── Emit ─────────────────────────────────────────────────────────────────────

pub fn writePeer(allocator: std.mem.Allocator, locator: model.PeerLocator) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeInto(allocator, &out, locator, .v1_0, null);
    return try out.toOwnedSlice(allocator);
}

/// Cache-key form of a peer URI: transport + designator only, hints stripped,
/// percent-encoding normalized through parse→write. Matches
/// `equality.peerLocatorsEqual` (hints are connection advice, not identity).
/// An unparseable string is returned as an exact dupe so verbatim exporter
/// overrides still join only on byte identity.
pub fn canonicalPeerIdentityUri(allocator: std.mem.Allocator, uri_str: []const u8) Error![]u8 {
    const parsed = parsePeer(allocator, uri_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try allocator.dupe(u8, uri_str),
    };
    defer model.freePeerLocator(allocator, parsed);
    const bare: model.PeerLocator = .{
        .transport = parsed.transport,
        .designator = parsed.designator,
        .hints = model.Hints.emptyFalse(),
    };
    return writePeer(allocator, bare);
}

/// Render the baseline Goblins-compatible sturdyref URI form.
pub fn writeSturdyref(allocator: std.mem.Allocator, sturdyref: model.SturdyRef) Error![]u8 {
    return writeSturdyrefForProfile(allocator, .v1_0, sturdyref);
}

pub fn writeSturdyrefForProfile(
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    sturdyref: model.SturdyRef,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeInto(allocator, &out, sturdyref.peer, profile, sturdyref.swissnum);
    return try out.toOwnedSlice(allocator);
}

fn writeInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    locator: model.PeerLocator,
    profile: model.CaptpVersion,
    swissnum: ?[]const u8,
) Error!void {
    try out.appendSlice(allocator, "ocapn://");
    try appendPercentEncoded(allocator, out, locator.designator, safeNetloc);
    try out.append(allocator, '.');
    // The transport uses `safeTransport`, not `safeNetloc`: a bare '.' in the
    // transport would re-split on parse (`splitNetloc` cuts on the last dot),
    // turning a dotted transport into a different locator. A designator dot stays
    // bare — it lands left of the delimiter and survives the last-dot split — so
    // only the transport half escapes '.'.
    try appendPercentEncoded(allocator, out, locator.transport, safeTransport);
    if (swissnum) |swiss| {
        try out.appendSlice(allocator, sturdyref_path_prefix);
        switch (profile) {
            .v1_0 => {
                const encoder = std.base64.url_safe_no_pad.Encoder;
                const encoded = try out.addManyAsSlice(allocator, encoder.calcSize(swiss.len));
                _ = encoder.encode(encoded, swiss);
            },
            .next => try appendPercentEncoded(allocator, out, swiss, safePath),
        }
    }
    if (locator.hints.entries.len > 0) {
        try out.append(allocator, '?');
        for (locator.hints.entries, 0..) |entry, i| {
            if (i > 0) try out.append(allocator, '&');
            try appendPercentEncoded(allocator, out, entry.name, safeQuery);
            try out.append(allocator, '=');
            try writeHintValue(allocator, out, entry.value);
        }
    }
}

fn writeHintValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: model.HintValue) Error!void {
    switch (value) {
        .string => |string| try appendPercentEncoded(allocator, out, string, safeQuery),
        .integer => |integer| {
            var buf: [24]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buf, "{d}", .{integer}) catch unreachable;
            try out.appendSlice(allocator, rendered);
        },
        .boolean => |boolean| try out.appendSlice(allocator, if (boolean) "true" else "false"),
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

/// The transport half of a netloc: `safeNetloc` minus '.', which is the
/// structural designator/transport delimiter. Escaping '.' here (as `%2E`) keeps
/// a dotted transport from re-splitting when `splitNetloc` cuts on the last dot.
fn safeTransport(c: u8) bool {
    return c != '.' and safeNetloc(c);
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
