//! A partner the test drives byte by byte: a raw TCP stream beside a byte-fed
//! core Host session, so a test chooses exactly which bytes cross the kernel
//! and when, with frames a real Host produced.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const stream_framing = glowcap.foundation.stream_framing;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const harness = @import("harness.zig");

pub const RawPartner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Null for a partner whose bytes a test hands over without a socket.
    stream: ?std.Io.net.Stream,
    /// Boxed: sessions hold their Host's address.
    host: *Host,
    session: *HostSession,
    /// Bytes read from the stream and not yet fed to `session`.
    inbox: std.ArrayList(u8) = .empty,

    pub const Role = enum { dialer, acceptor };

    /// A partner over `stream` whose session plays `role` toward a runtime
    /// that advertises `designator` on `transport`.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        /// Null for a partner whose bytes a test hands over without a socket.
        stream: ?std.Io.net.Stream,
        role: Role,
        transport: []const u8,
        /// A profile the partner's Host learns before opening, for a transport
        /// the library does not know.
        profile: ?model.transport.Metadata,
        designator: []const u8,
    ) !RawPartner {
        const host = try allocator.create(Host);
        errdefer allocator.destroy(host);
        host.* = test_host.init(allocator, @as([32]u8, @splat(0x61)), Host.Options.init(.unchecked, harness.frame_cap));
        errdefer host.deinit();
        if (profile) |defined| {
            var canonical: [1][]const u8 = undefined;
            try host.defineTransports(&.{defined}, &canonical);
        }
        const locator: model.PeerLocator = .{ .transport = transport, .designator = designator, .hints = model.Hints.emptyFalse() };
        const session = switch (role) {
            .dialer => blk: {
                try host.ensureAdvertisedLocator(transport);
                break :blk try host.openDialedLocator(locator);
            },
            .acceptor => blk: {
                try host.setAdvertisedLocator(locator);
                break :blk try host.openAcceptedAdvertised(transport);
            },
        };
        return .{ .allocator = allocator, .io = io, .stream = stream, .host = host, .session = session };
    }

    pub fn deinit(self: *RawPartner) void {
        self.inbox.deinit(self.allocator);
        self.host.deinit();
        self.allocator.destroy(self.host);
        if (self.stream) |stream| stream.close(self.io);
    }

    /// Wait up to `timeout_ms` for bytes, append what arrived to the inbox,
    /// and return how many.
    pub fn readSome(self: *RawPartner, timeout_ms: i32) !usize {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.stream.?.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        if (try std.posix.poll(&fds, timeout_ms) == 0) return 0;
        var chunk: [4096]u8 = undefined;
        const got = try std.posix.read(self.stream.?.socket.handle, &chunk);
        if (got == 0) return error.EndOfStream;
        try self.inbox.appendSlice(self.allocator, chunk[0..got]);
        return got;
    }

    /// Feed every inbox byte to the partner's session.
    pub fn feedInbox(self: *RawPartner) !void {
        defer self.inbox.clearRetainingCapacity();
        try self.host.feedBytes(self.session, self.inbox.items);
    }

    /// Every frame the partner's session has queued, outer-framed, in order.
    pub fn takeWire(self: *RawPartner, out: *std.ArrayList(u8)) !void {
        while (try self.session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
            try out.appendSlice(self.allocator, stream_framing.renderPrefix(&prefix_buf, frame.bytes().len));
            try out.appendSlice(self.allocator, frame.bytes());
        }
    }

    pub fn writeAll(self: *RawPartner, bytes: []const u8) !void {
        var buf: [256]u8 = undefined;
        var writer = self.stream.?.writer(self.io, &buf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }
};

/// Whether `fd` reports readable now.
pub fn readable(fd: i32) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, 0) != 0;
}

/// Whether `fd` becomes readable within `timeout_ms`.
pub fn becomesReadable(fd: i32, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, timeout_ms) != 0;
}
