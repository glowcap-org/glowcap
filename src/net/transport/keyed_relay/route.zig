//! Relay-owned URL, hint, and rendezvous-query policy.
//!
//! Views borrow their admitted input. Long-lived residents retain that storage.
//! WebSocket carriers receive the parsed route and never reinterpret locators.

const std = @import("std");

const model = @import("model");
const tcp = @import("../tcp.zig");

/// The relay's rendezvous-leg query key (`?rendezvous=<designator>`).
pub const rendezvous_query = "rendezvous";
/// The relay's registration query key (`?id=<designator>`).
pub const register_query = "id";

/// Locator hint carrying the relay endpoint at which the designator is
/// registered. It is routing advice, not a second identity field. The
/// rendezvous query remains keyed by the locator designator.
pub const rendezvous_relay_hint = "rendezvous-relay";

/// A peer-supplied relay URL is untrusted routing input. Bound its
/// retained and parsed request-target cost independently of deployment config.
pub const max_rendezvous_relay_hint_bytes: usize = 4 * 1024;

pub const Leg = enum {
    rendezvous,
    register,

    pub fn queryName(self: Leg) []const u8 {
        return switch (self) {
            .rendezvous => rendezvous_query,
            .register => register_query,
        };
    }
};

pub const Scheme = enum {
    ws,
    wss,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .ws => 80,
            .wss => 443,
        };
    }

    pub fn secure(self: Scheme) bool {
        return self == .wss;
    }
};

/// One fully selected relay-channel request. The relay owns the query meaning.
/// A carrier receives only the validated endpoint and request-target pieces.
pub const OpenRequest = struct {
    endpoint: RelayUrl,
    leg: Leg,
    query_value: []const u8,

    pub fn path(self: OpenRequest) []const u8 {
        return if (self.endpoint.path.len == 0) "/" else self.endpoint.path;
    }

    pub fn fixedQueryPrefix(self: OpenRequest) []const u8 {
        return if (self.endpoint.query) |query| query else "";
    }

    pub fn queryJoin(self: OpenRequest) u8 {
        return if (self.endpoint.query == null) '?' else '&';
    }

    pub fn queryName(self: OpenRequest) []const u8 {
        return self.leg.queryName();
    }
};

/// A parsed WebSocket relay endpoint. Every view borrows the input URL
/// string, so a long-lived adapter retains that storage beside this value.
/// Hosts are either IP literals or validated ASCII DNS names.
pub const RelayUrl = struct {
    scheme: Scheme,
    /// Host text for socket resolution, with IPv6 brackets removed.
    host: []const u8,
    /// Verbatim validated HTTP authority. It retains IPv6 brackets and an
    /// explicit port, while a defaulted port remains absent.
    authority: []const u8,
    port: u16,
    /// The path including its leading `/`. Empty means `/`.
    path: []const u8,
    /// The fixed query including its leading `?`, when the deployment URL
    /// carries one. The relay appends its owned query pair after this slice.
    query: ?[]const u8,

    pub fn parse(url: []const u8) error{InvalidRelayUrl}!RelayUrl {
        const scheme: Scheme, const rest = if (std.mem.startsWith(u8, url, "ws://"))
            .{ .ws, url["ws://".len..] }
        else if (std.mem.startsWith(u8, url, "wss://"))
            .{ .wss, url["wss://".len..] }
        else
            return error.InvalidRelayUrl;
        const suffix_at = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..suffix_at];
        const endpoint = try parseAuthority(scheme, authority);
        const suffix = rest[suffix_at..];
        // This slice is written verbatim as the HTTP request target. Admit only
        // visible ASCII URI bytes and no fragment: controls or whitespace would
        // inject or split a request, while a fragment is never sent to a server.
        for (suffix) |byte| {
            if (byte < 0x21 or byte > 0x7e or byte == '#') return error.InvalidRelayUrl;
        }
        const query_at = std.mem.indexOfScalar(u8, suffix, '?');
        const path = suffix[0 .. query_at orelse suffix.len];
        if (path.len != 0 and path[0] != '/') return error.InvalidRelayUrl;
        const query = if (query_at) |at| suffix[at..] else null;
        try validateTarget(path, query);
        return .{
            .scheme = scheme,
            .host = endpoint.host,
            .authority = authority,
            .port = endpoint.port,
            .path = path,
            .query = query,
        };
    }

    pub fn openRequest(
        self: RelayUrl,
        leg: Leg,
        query_value: []const u8,
    ) OpenRequest {
        return .{
            .endpoint = self,
            .leg = leg,
            .query_value = query_value,
        };
    }
};

const ParsedAuthority = struct {
    host: []const u8,
    port: u16,
};

fn parseAuthority(scheme: Scheme, authority: []const u8) error{InvalidRelayUrl}!ParsedAuthority {
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null)
        return error.InvalidRelayUrl;

    var host: []const u8 = undefined;
    var port = scheme.defaultPort();
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse
            return error.InvalidRelayUrl;
        if (close == 1) return error.InvalidRelayUrl;
        host = authority[1..close];
        const tail = authority[close + 1 ..];
        if (tail.len != 0) {
            if (tail[0] != ':') return error.InvalidRelayUrl;
            port = try parsePort(tail[1..]);
        }
        _ = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidRelayUrl;
        if (std.mem.indexOfScalar(u8, host, ':') == null) return error.InvalidRelayUrl;
    } else {
        if (std.mem.indexOfScalar(u8, authority, '[') != null or
            std.mem.indexOfScalar(u8, authority, ']') != null)
            return error.InvalidRelayUrl;
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        if (colon) |at| {
            if (std.mem.indexOfScalarPos(u8, authority, at + 1, ':') != null)
                return error.InvalidRelayUrl;
            host = authority[0..at];
            port = try parsePort(authority[at + 1 ..]);
        } else {
            host = authority;
        }
        if (host.len == 0) return error.InvalidRelayUrl;
        if (tcp.parseHostPort(host, port)) |_| {} else |_| {
            std.Io.net.HostName.validate(host) catch return error.InvalidRelayUrl;
        }
    }
    return .{ .host = host, .port = port };
}

fn parsePort(text: []const u8) error{InvalidRelayUrl}!u16 {
    if (text.len == 0) return error.InvalidRelayUrl;
    for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidRelayUrl;
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidRelayUrl;
    if (port == 0) return error.InvalidRelayUrl;
    return port;
}

fn validateTarget(path: []const u8, query: ?[]const u8) error{InvalidRelayUrl}!void {
    try validatePercentEncoding(path);
    const fixed = query orelse return;
    try validatePercentEncoding(fixed);

    var fields = std.mem.splitScalar(u8, fixed[1..], '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        const name = field[0..equals];
        if (encodedEquals(name, rendezvous_query) or encodedEquals(name, register_query))
            return error.InvalidRelayUrl;
    }
}

fn validatePercentEncoding(target: []const u8) error{InvalidRelayUrl}!void {
    // The same RFC 3986 escape shape the URI reader owns; only the error
    // name is this transport's.
    model.uri.validatePercentEncoding(target) catch return error.InvalidRelayUrl;
}

fn encodedEquals(encoded: []const u8, expected: []const u8) bool {
    var encoded_at: usize = 0;
    var expected_at: usize = 0;
    while (encoded_at < encoded.len and expected_at < expected.len) : (expected_at += 1) {
        const byte = if (encoded[encoded_at] == '%') blk: {
            if (encoded_at + 2 >= encoded.len) return false;
            const high = hexValue(encoded[encoded_at + 1]) orelse return false;
            const low = hexValue(encoded[encoded_at + 2]) orelse return false;
            encoded_at += 3;
            break :blk (high << 4) | low;
        } else blk: {
            const literal = encoded[encoded_at];
            encoded_at += 1;
            break :blk literal;
        };
        if (byte != expected[expected_at]) return false;
    }
    return encoded_at == encoded.len and expected_at == expected.len;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// Parse the optional relay-route hint once for every relay execution model. A
/// present hint must be one bounded, non-empty string URL. Duplicate names are
/// invalid even when their values agree.
pub fn relayHint(hints: model.Hints) error{InvalidRelayHint}!?RelayUrl {
    var selected: ?RelayUrl = null;
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, rendezvous_relay_hint)) continue;
        if (selected != null) return error.InvalidRelayHint;
        const text = switch (entry.value) {
            .string => |value| value,
            else => return error.InvalidRelayHint,
        };
        if (text.len == 0 or text.len > max_rendezvous_relay_hint_bytes)
            return error.InvalidRelayHint;
        selected = RelayUrl.parse(text) catch return error.InvalidRelayHint;
    }
    return selected;
}
