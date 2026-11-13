//! The encrypted transport the Zig demo programs use: Noise_XK over TCP.
//!
//! A server listens under a fresh session secret and prints its locator, an
//! `ocapn://` URI that names the server's key and its address. A client dials
//! that URI, and finishing the handshake proves it reached the key the URI
//! names. Nobody else on the network can read or alter the session.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const tcp = glowcap.net.tcp;

/// The one transport a demo program serves and dials.
pub const transports: driver.Transports = .{ .symbols = &.{.noise_tcp} };

/// Room for a printed locator: the transport, the key designator, and one
/// loopback address.
pub const locator_buf_len = 256;

/// Listen on loopback `port` (0 for any free port) under a fresh session
/// secret. The returned server's `deinit` releases it.
pub fn listen(allocator: std.mem.Allocator, io: std.Io, port: u16, opts: driver.SessionOptions) !*driver.Server {
    var bind_buf: [tcp.designator_buf_len]u8 = undefined;
    const bind = try std.mem.print(&bind_buf, "127.0.0.1:{d}", .{port});
    return driver.listen(allocator, io, transports, model.transport.noise_tcp, .{ .designator = bind }, .{ .keyed = try driver.drawSessionSecret(io) }, opts);
}

/// What a demo server prints so a client can reach it.
pub const Announcement = struct {
    /// The port the listener bound.
    port: u16,
    /// The locator URI, borrowed from the buffer `announce` wrote it into.
    locator: []const u8,
};

/// The bound port and the server's locator URI, written into `buf`. A
/// key-addressed locator carries its address in a hint, and a plain TCP
/// locator is its address.
pub fn announce(server: *driver.Server, buf: *[locator_buf_len]u8) !Announcement {
    const locator = try server.advertisedLocator();
    const address = if (glowcap.net.netlayer.directAddrHint(locator.hints)) |direct| model.uri.firstDirectAddress(direct) else locator.designator;
    const port: u16 = switch (try tcp.parseDesignator(address)) {
        .ip4 => |ip| ip.port,
        .ip6 => |ip| ip.port,
    };
    const written = try model.uri.writePeerBounded(locator, buf);
    if (!written.complete) return error.LocatorTooLong;
    return .{ .port = port, .locator = buf[0..written.len] };
}

/// Dial the locator URI a demo server printed. A locator on any other
/// transport is refused.
pub fn connect(allocator: std.mem.Allocator, io: std.Io, uri: []const u8, opts: driver.SessionOptions) !*driver.Session {
    return driver.connectUri(allocator, io, transports, uri, .ephemeral, opts);
}
