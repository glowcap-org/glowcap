//! Allocation-free RFC 3986 decomposition for OCapN URI forms.
//!
//! Zig's generic URI reader treats every reg-name authority as a DNS hostname
//! and rejects an encoded authority beyond its network-hostname ceiling. OCapN's
//! authority is not a DNS hostname: it is an arbitrary percent-encoded
//! designator followed by a transport symbol. This reader owns the narrower
//! shape OCapN needs without importing that unrelated DNS limit.

const std = @import("std");

pub const Error = error{
    MalformedPercentEncoding,
    UnsupportedUriComponent,
    UriParseError,
};

pub const View = struct {
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
    query: ?[]const u8,
};

pub fn inspect(text: []const u8) Error!View {
    try validatePercentEncoding(text);

    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.UriParseError;
    const scheme = text[0..colon];
    if (!validScheme(scheme)) return error.UriParseError;

    const authority_start = colon + 1;
    if (!std.mem.startsWith(u8, text[authority_start..], "//"))
        return error.UriParseError;
    const host_start = authority_start + 2;
    const host_end = std.mem.indexOfAnyPos(u8, text, host_start, "/?#") orelse text.len;
    const authority = text[host_start..host_end];
    if (authority.len == 0) return error.UriParseError;
    if (std.mem.indexOfAny(u8, authority, "@:") != null)
        return error.UnsupportedUriComponent;

    const fragment = std.mem.indexOfScalarPos(u8, text, host_end, '#');
    if (fragment != null) return error.UnsupportedUriComponent;

    const query_mark = std.mem.indexOfScalarPos(u8, text, host_end, '?');
    const path_end = query_mark orelse text.len;
    const path = text[host_end..path_end];
    const query = if (query_mark) |at| text[at + 1 ..] else null;
    return .{
        .scheme = scheme,
        .authority = authority,
        .path = path,
        .query = query,
    };
}

fn validScheme(scheme: []const u8) bool {
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.')
            return false;
    }
    return true;
}

pub fn validatePercentEncoding(bytes: []const u8) Error!void {
    var at: usize = 0;
    while (at < bytes.len) : (at += 1) {
        if (bytes[at] != '%') continue;
        if (at + 2 >= bytes.len or !std.ascii.isHex(bytes[at + 1]) or !std.ascii.isHex(bytes[at + 2]))
            return error.MalformedPercentEncoding;
        at += 2;
    }
}
