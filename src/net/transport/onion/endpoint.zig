//! Where a local Tor daemon listens.
//!
//! Both of Tor's endpoints, the SOCKS port and the control port, are reached the
//! same two ways: an address and port, or a Unix socket path. The pinned Spritely
//! Goblins uses Unix sockets for both and defaults them under
//! `~/.cache/goblins/tor/`; a distribution's Tor commonly offers a loopback
//! `SocksPort` instead. glowcap takes either, and takes it from configuration
//! rather than guessing, because a daemon it did not start is not one it can
//! assume the shape of.
//!
//! The two forms are told apart by the leading character. A path is absolute, so
//! it begins with `/`; anything else is parsed as `host:port`. A relative path is
//! refused rather than guessed at, which keeps `tor-control-sock` from being read
//! as a hostname whose port is missing.

const std = @import("std");
const socket = @import("../../socket.zig");

const IpAddress = std.Io.net.IpAddress;
const UnixAddress = std.Io.net.UnixAddress;
const Stream = std.Io.net.Stream;
const Server = std.Io.net.Server;

pub const Error = error{
    /// The text is neither an absolute Unix socket path nor a parseable
    /// `host:port`.
    InvalidEndpoint,
};

/// The endpoint text a config carries, resolved to something dialable.
pub const Endpoint = union(enum) {
    address: IpAddress,
    /// Borrowed for the life of the endpoint. The caller owns the bytes, which
    /// for a resident means the configuration outlives every connection.
    unix: []const u8,

    /// Parse configuration text. `/run/tor/control` is a socket path,
    /// `127.0.0.1:9050` is an address, and `tor-control-sock` is neither.
    pub fn parse(text: []const u8) Error!Endpoint {
        if (text.len == 0) return Error.InvalidEndpoint;
        if (text[0] == '/') {
            if (text.len > UnixAddress.max_len) return Error.InvalidEndpoint;
            return .{ .unix = text };
        }
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return Error.InvalidEndpoint;
        const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return Error.InvalidEndpoint;
        const host = text[0..colon];
        // A bracketed IPv6 literal keeps its brackets in the text and loses them
        // here, the same shape `tcp.parseDesignator` accepts.
        const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
            host[1 .. host.len - 1]
        else
            host;
        const address = IpAddress.parse(bare, port) catch return Error.InvalidEndpoint;
        return .{ .address = address };
    }

    pub const ConnectError = IpAddress.ConnectError || UnixAddress.ConnectError;

    /// Open a stream to this endpoint. The TCP arm disables Nagle: the hop
    /// carries small sequential SOCKS and CapTP writes to the local Tor
    /// client, and a refused option keeps the working connection because the
    /// loss is throughput only.
    pub fn connect(self: Endpoint, io: std.Io) ConnectError!Stream {
        return switch (self) {
            .address => |addr| blk: {
                const stream = try IpAddress.connect(&addr, io, .{ .mode = .stream });
                socket.applyNodelay(stream.socket.handle) catch {}; // tolerant: throughput only
                break :blk stream;
            },
            .unix => |path| blk: {
                const ua = UnixAddress.init(path) catch return error.FileNotFound;
                break :blk UnixAddress.connect(&ua, io);
            },
        };
    }

    pub const ListenError = IpAddress.ListenError || UnixAddress.ListenError;

    /// Bind and listen on this endpoint. This is the local end Tor forwards a
    /// service's virtual port to, never a public address.
    pub fn listen(self: Endpoint, io: std.Io) ListenError!Server {
        return switch (self) {
            .address => |addr| IpAddress.listen(&addr, io, .{ .reuse_address = true }),
            .unix => |path| blk: {
                const ua = UnixAddress.init(path) catch return error.FileNotFound;
                break :blk UnixAddress.listen(&ua, io, .{});
            },
        };
    }

    /// Whether this endpoint is a Unix socket path, which decides whether a
    /// forward target is written as `unix:<path>` or as `addr:port`.
    pub fn isUnix(self: Endpoint) bool {
        return self == .unix;
    }
};
