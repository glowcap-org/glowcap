//! Turning an OCapN locator into an `ocapn://` URI and back — the out-of-band
//! bootstrap form the OCapN `Locators` spec defines.
//!
//! A peer URI is `ocapn://<designator>.<transport>[?k=v&…]`; a sturdyref adds
//! `/s/<swiss-num>` before any query. This is how a peer address — a `tcp`
//! host/port, an `onion` service id, a self-authenticating key on any
//! netlayer — is handed out of band to bootstrap a session, the same format the
//! reference suite and Goblins exchange.
//!
//! Parsing uses the allocation-free OCapN URI-shape reader; percent-decoding
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
const uri_shape = @import("uri_shape.zig");

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

/// The RFC 3986 escape-shape check, offered where URI callers already look:
/// every `%` must carry two hex digits. Transports validating their own URL
/// forms call through here rather than growing a second copy of the shape.
pub const validatePercentEncoding = uri_shape.validatePercentEncoding;

pub fn freeSturdyref(allocator: std.mem.Allocator, sturdyref: model.SturdyRef) void {
    model.freePeerLocator(allocator, sturdyref.peer);
    allocator.free(sturdyref.swissnum);
}

/// Percent-decode `s` into a fresh owned allocation. Uses `std.Uri.percentDecodeInPlace`
/// on a mutable copy.
fn percentDecodeOwned(allocator: std.mem.Allocator, s: []const u8) Error![]u8 {
    uri_shape.validatePercentEncoding(s) catch return error.MalformedPercentEncoding;
    const buf = try allocator.dupe(u8, s);
    errdefer allocator.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    if (decoded.len == buf.len) return buf;
    // Shrunk after decode; realloc to exact size.
    const exact = try allocator.dupe(u8, decoded);
    allocator.free(buf);
    return exact;
}

fn parseUri(uri_str: []const u8) Error!uri_shape.View {
    return uri_shape.inspect(uri_str) catch |err| switch (err) {
        error.MalformedPercentEncoding => error.MalformedPercentEncoding,
        error.UnsupportedUriComponent => error.UnsupportedUriComponent,
        error.UriParseError => error.UriParseError,
    };
}

/// Split the netloc into designator and transport on the last dot. The split
/// happens on the **percent-encoded** form (so an escaped `.` in the designator
/// is data, not a structural delimiter), then each side percent-decodes
/// individually, the same discipline as `decodeHints`.
fn splitNetloc(allocator: std.mem.Allocator, netloc_pe: []const u8) Error!struct { transport: []u8, designator: []u8 } {
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
fn decodeHintBytes(allocator: std.mem.Allocator, query: ?[]const u8) Error!model.Hints {
    const q = query orelse return model.Hints.emptyFalse();
    if (q.len == 0) return .{ .entries = &.{}, .wire_form = .map };

    var entries: std.ArrayList(model.HintEntry) = .empty;
    errdefer {
        for (entries.items) |entry| model.freeHintEntry(allocator, entry);
        entries.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |segment| {
        if (entries.items.len == model.max_locator_hint_count)
            return Error.InvalidLocator;
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse return Error.MalformedHint;
        const name = try percentDecodeOwned(allocator, segment[0..eq]);
        errdefer allocator.free(name);
        const value = try percentDecodeOwned(allocator, segment[eq + 1 ..]);
        errdefer allocator.free(value);
        try entries.append(allocator, .{ .name = name, .value = .{ .string = value } });
    }

    return .{ .entries = try entries.toOwnedSlice(allocator), .wire_form = .map };
}

/// Materialize components already decomposed and shape-checked by the shared
/// route-list reader. This keeps one URI parse on the route admission path.
fn parsePeerInspected(
    allocator: std.mem.Allocator,
    transport_encoded: []const u8,
    designator_encoded: []const u8,
    query_encoded: ?[]const u8,
) Error!model.PeerLocator {
    const transport = try percentDecodeOwned(allocator, transport_encoded);
    errdefer allocator.free(transport);
    const designator = try percentDecodeOwned(allocator, designator_encoded);
    errdefer allocator.free(designator);
    const hints = try decodeHintBytes(allocator, query_encoded);
    errdefer model.freeHints(allocator, hints);
    const locator: model.PeerLocator = .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
    model.validatePeerLocator(locator) catch return error.InvalidLocator;
    return locator;
}

pub const Internal = struct {
    pub const materializeInspectedPeer = parsePeerInspected;
};

pub fn parsePeer(allocator: std.mem.Allocator, uri_str: []const u8) Error!model.PeerLocator {
    const uri = try parseUri(uri_str);
    if (!std.mem.eql(u8, uri.scheme, scheme_str)) return Error.NotOcapnUri;

    const nl = try splitNetloc(allocator, uri.authority);
    errdefer allocator.free(nl.transport);
    errdefer allocator.free(nl.designator);

    // A peer URI has no path; reject if present (sturdyrefs have `/s/…`).
    const path_pe = uri.path;
    if (path_pe.len > 0) return Error.MalformedPath;

    const hints = try decodeHintBytes(allocator, uri.query);
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

    const nl = try splitNetloc(allocator, uri.authority);
    errdefer allocator.free(nl.transport);
    errdefer allocator.free(nl.designator);

    const path_pe = uri.path;
    if (!std.mem.startsWith(u8, path_pe, sturdyref_path_prefix)) return Error.MalformedPath;
    const swiss_pe = path_pe[sturdyref_path_prefix.len..];

    const swissnum = try decodeSwissNumber(allocator, profile, swiss_pe);
    errdefer allocator.free(swissnum);

    const hints = try decodeHintBytes(allocator, uri.query);
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

/// The first entry of a comma-separated `direct-addresses` hint, trimmed.
/// A `keyed-tcp` hint carries the address(es) to dial; an implementation that
/// published several picks the first. Returns a sub-slice of `hint` (empty when
/// the first entry is empty or the hint is only separators).
pub fn firstDirectAddress(hint: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, hint, ',') orelse hint.len;
    return std.mem.trim(u8, hint[0..comma], " \t");
}

/// Split a `host:port` designator — the address grammar a socket transport's
/// locator designator carries. The split is on the **last** colon, so a
/// bracketed IPv6 literal such as `[::1]:9000` keeps its address intact; the
/// brackets are stripped from the returned host, the form a host resolver
/// expects. The port must be a decimal `u16` and the host must be non-empty.
/// This is the one definition of that grammar: the native TCP netlayer and the
/// C ABI (`glowcap_designator_host_port` / `glowcap_locator_host_port`) both split
/// through it, so a consumer dialing with its own sockets validates the same
/// way the native dialer does.
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
