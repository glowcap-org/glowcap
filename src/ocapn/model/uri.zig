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
    InvalidLocator,
    UriParseError,
    MalformedPercentEncoding,
    UnsupportedUriComponent,
    InvalidHostPort,
    /// `tcpConnectHostPort` was asked for a transport it does not resolve
    /// (`tcp`, `keyed-tcp`, and `noise-tcp` only).
    UnknownTransport,
    /// A `keyed-tcp` or `noise-tcp` dial has no usable `direct-addresses`
    /// hint entry.
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
    try validatePercentEncoding(s);
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
    try validatePercentEncoding(uri_str);
    const uri = std.Uri.parse(uri_str) catch return Error.UriParseError;
    if (uri.user != null or uri.password != null or uri.port != null or uri.fragment != null)
        return error.UnsupportedUriComponent;
    return uri;
}

fn validatePercentEncoding(bytes: []const u8) Error!void {
    var at: usize = 0;
    while (at < bytes.len) : (at += 1) {
        if (bytes[at] != '%') continue;
        if (at + 2 >= bytes.len or !isHex(bytes[at + 1]) or !isHex(bytes[at + 2]))
            return error.MalformedPercentEncoding;
        at += 2;
    }
}

fn isHex(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
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
    errdefer model.freeHints(allocator, hints);
    const locator: model.PeerLocator = .{ .transport = nl.transport, .designator = nl.designator, .hints = hints };
    model.validatePeerLocator(locator) catch return error.InvalidLocator;
    return locator;
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
    errdefer model.freeHints(allocator, hints);
    const peer: model.PeerLocator = .{ .transport = nl.transport, .designator = nl.designator, .hints = hints };
    model.validatePeerLocator(peer) catch return error.InvalidLocator;
    return .{
        .peer = peer,
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

/// Resolve the TCP provider's connect `host:port` from locator pieces. This is
/// the one admission for `tcp` / `keyed-tcp` / `noise-tcp` hostport
/// selection: `planDial` and `tcp.DialResolver` both call it so the
/// first-address / split grammar cannot drift. Key-shape checks stay with the
/// callers that own crypto (`PeerKey.fromDesignator`). Views borrow
/// `designator` or `hint`.
pub fn tcpConnectHostPort(
    transport: []const u8,
    designator: []const u8,
    direct_addresses_hint: []const u8,
) Error!HostPort {
    const known = model.transport.parseKnown(transport) orelse return Error.UnknownTransport;
    return connectHostPort(known.metadata(), designator, direct_addresses_hint);
}

pub fn connectHostPort(
    profile: model.transport.Metadata,
    designator: []const u8,
    direct_addresses_hint: []const u8,
) Error!HostPort {
    return switch (profile.address_source) {
        .none => Error.UnknownTransport,
        .designator => splitHostPort(designator),
        .direct_addresses_hint => {
            if (direct_addresses_hint.len == 0) return Error.MissingDirectAddressesHint;
            const first = firstDirectAddress(direct_addresses_hint);
            if (first.len == 0) return Error.MissingDirectAddressesHint;
            return splitHostPort(first);
        },
    };
}

// ── Emit ─────────────────────────────────────────────────────────────────────

pub const BoundedWrite = struct {
    len: usize,
    complete: bool,
};

const ListSink = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),

    fn appendSlice(self: *ListSink, bytes: []const u8) Error!void {
        self.out.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }

    fn append(self: *ListSink, byte: u8) Error!void {
        self.out.append(self.allocator, byte) catch return error.OutOfMemory;
    }

    fn appendBase64UrlNoPad(self: *ListSink, bytes: []const u8) Error!void {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = self.out.addManyAsSlice(self.allocator, encoder.calcSize(bytes.len)) catch return error.OutOfMemory;
        _ = encoder.encode(encoded, bytes);
    }
};

const CountSink = struct {
    len: usize = 0,

    fn advance(self: *CountSink, amount: usize) Error!void {
        self.len = std.math.add(usize, self.len, amount) catch return error.OutOfMemory;
    }

    fn appendSlice(self: *CountSink, bytes: []const u8) Error!void {
        try self.advance(bytes.len);
    }

    fn append(self: *CountSink, byte: u8) Error!void {
        _ = byte;
        try self.advance(1);
    }

    fn appendBase64UrlNoPad(self: *CountSink, bytes: []const u8) Error!void {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        try self.advance(encoder.calcSize(bytes.len));
    }
};

const BoundedSink = struct {
    buf: []u8,
    len: usize = 0,
    complete: bool = true,

    fn advance(self: *BoundedSink, amount: usize) Error!usize {
        const start = self.len;
        self.len = std.math.add(usize, self.len, amount) catch return error.OutOfMemory;
        return start;
    }

    fn canWrite(self: *BoundedSink, start: usize, amount: usize) bool {
        return self.complete and start <= self.buf.len and amount <= self.buf.len - start;
    }

    fn appendSlice(self: *BoundedSink, bytes: []const u8) Error!void {
        const start = try self.advance(bytes.len);
        if (!self.canWrite(start, bytes.len)) {
            self.complete = false;
            return;
        }
        @memcpy(self.buf[start..][0..bytes.len], bytes);
    }

    fn append(self: *BoundedSink, byte: u8) Error!void {
        const start = try self.advance(1);
        if (!self.canWrite(start, 1)) {
            self.complete = false;
            return;
        }
        self.buf[start] = byte;
    }

    fn appendBase64UrlNoPad(self: *BoundedSink, bytes: []const u8) Error!void {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded_len = encoder.calcSize(bytes.len);
        const start = try self.advance(encoded_len);
        if (!self.canWrite(start, encoded_len)) {
            self.complete = false;
            return;
        }
        _ = encoder.encode(self.buf[start..][0..encoded_len], bytes);
    }
};

pub fn writePeer(allocator: std.mem.Allocator, locator: model.PeerLocator) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var sink: ListSink = .{ .allocator = allocator, .out = &out };
    try writeInto(&sink, locator, .v1_0, null);
    return try out.toOwnedSlice(allocator);
}

pub fn measurePeer(locator: model.PeerLocator) Error!usize {
    var sink: CountSink = .{};
    try writeInto(&sink, locator, .v1_0, null);
    return sink.len;
}

pub fn writePeerBounded(locator: model.PeerLocator, out: []u8) Error!BoundedWrite {
    var sink: BoundedSink = .{ .buf = out };
    try writeInto(&sink, locator, .v1_0, null);
    return .{ .len = sink.len, .complete = sink.complete };
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
    var sink: ListSink = .{ .allocator = allocator, .out = &out };
    try writeInto(&sink, sturdyref.peer, profile, sturdyref.swissnum);
    return try out.toOwnedSlice(allocator);
}

pub fn measureSturdyrefForProfile(
    profile: model.CaptpVersion,
    sturdyref: model.SturdyRef,
) Error!usize {
    var sink: CountSink = .{};
    try writeInto(&sink, sturdyref.peer, profile, sturdyref.swissnum);
    return sink.len;
}

pub fn writeSturdyrefForProfileBounded(
    profile: model.CaptpVersion,
    sturdyref: model.SturdyRef,
    out: []u8,
) Error!BoundedWrite {
    var sink: BoundedSink = .{ .buf = out };
    try writeInto(&sink, sturdyref.peer, profile, sturdyref.swissnum);
    return .{ .len = sink.len, .complete = sink.complete };
}

fn writeInto(
    sink: anytype,
    locator: model.PeerLocator,
    profile: model.CaptpVersion,
    swissnum: ?[]const u8,
) Error!void {
    model.validatePeerLocator(locator) catch return error.InvalidLocator;
    try sink.appendSlice("ocapn://");
    try appendPercentEncoded(sink, locator.designator, safeNetloc);
    try sink.append('.');
    try appendPercentEncoded(sink, locator.transport, safeNetloc);
    if (swissnum) |swiss| {
        try sink.appendSlice(sturdyref_path_prefix);
        switch (profile) {
            .v1_0 => try sink.appendBase64UrlNoPad(swiss),
            .next => try appendPercentEncoded(sink, swiss, safePath),
        }
    }
    if (locator.hints.entries.len > 0) {
        try sink.append('?');
        for (locator.hints.entries, 0..) |entry, i| {
            if (i > 0) try sink.append('&');
            try appendPercentEncoded(sink, entry.name, safeQuery);
            try sink.append('=');
            try writeHintValue(sink, entry.value);
        }
    }
}

fn writeHintValue(sink: anytype, value: model.HintValue) Error!void {
    switch (value) {
        .string => |string| try appendPercentEncoded(sink, string, safeQuery),
        .integer => |integer| {
            var buf: [24]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buf, "{d}", .{integer}) catch unreachable;
            try sink.appendSlice(rendered);
        },
        .boolean => |boolean| try sink.appendSlice(if (boolean) "true" else "false"),
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
    sink: anytype,
    s: []const u8,
    comptime safe: fn (u8) bool,
) Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (safe(c)) {
            try sink.append(c);
        } else {
            try sink.append('%');
            try sink.append(hex[c >> 4]);
            try sink.append(hex[c & 0xf]);
        }
    }
}
