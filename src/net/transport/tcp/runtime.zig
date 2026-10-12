//! Raw TCP socket realization shared by every TCP profile and projection.
//!
//! This module owns the one transition from `std.Io` to TCP sockets: dialing,
//! binding, accepting, stream tuning, readiness, byte I/O, and close. OCapN
//! locator/profile semantics stay in the sibling adapters. Engine connections
//! and C callbacks both project this same runtime instead of reimplementing it.

const std = @import("std");
const builtin = @import("builtin");

const accept_gate = @import("../../accept_gate.zig");
const socket = @import("../../socket.zig");

const IpAddress = std.Io.net.IpAddress;
const Socket = std.Io.net.Socket;
const Stream = std.Io.net.Stream;
const Server = std.Io.net.Server;

pub const Keepalive = socket.Keepalive;
pub const ConfigurationError = socket.ConfigurationError;
pub const WaitError = accept_gate.WaitError;
pub const AcceptError = WaitError || ConfigurationError;

pub const StreamOptions = struct {
    keepalive: ?Keepalive = null,
};

fn configureStream(stream: Stream, options: StreamOptions) ConfigurationError!void {
    try socket.applyNodelay(stream.socket.handle);
    if (options.keepalive) |keepalive| try socket.applyKeepalive(stream.socket.handle, keepalive);
}

pub fn connectStream(io: std.Io, address: IpAddress, options: StreamOptions) (IpAddress.ConnectError || ConfigurationError)!Stream {
    const stream = try IpAddress.connect(&address, io, .{ .mode = .stream });
    errdefer stream.close(io);
    try configureStream(stream, options);
    return stream;
}

/// One open TCP byte stream. The value must remain at a stable address while
/// either reader/writer interface is borrowed.
pub const Connection = struct {
    reader: Stream.Reader,
    writer: Stream.Writer,
    io: std.Io,

    pub fn over(
        io: std.Io,
        stream: Stream,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) ConfigurationError!Connection {
        try configureStream(stream, options);
        return .{
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .io = io,
        };
    }

    pub fn connect(
        io: std.Io,
        address: IpAddress,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) (IpAddress.ConnectError || ConfigurationError)!Connection {
        const stream = try connectStream(io, address, options);
        return .{
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .io = io,
        };
    }

    pub fn readinessFd(self: *const Connection) Socket.Handle {
        return self.reader.stream.socket.handle;
    }

    pub fn read(self: *Connection, out: []u8) std.Io.Reader.Error!usize {
        var slices = [_][]u8{out};
        return self.reader.interface.readVec(&slices);
    }

    pub fn writeAll(self: *Connection, bytes: []const u8) std.Io.Writer.Error!void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }

    pub fn close(self: *Connection) void {
        self.reader.stream.close(self.io);
    }
};

/// A bound TCP socket. Shutdown interrupts an in-flight readiness or accept
/// wait through the accept gate's private wake descriptor. Deinit joins that
/// operation before releasing storage.
pub const Listener = struct {
    server: Server,
    io: std.Io,
    gate: accept_gate.Gate,

    pub fn bind(io: std.Io, address: IpAddress) (IpAddress.ListenError || error{WakeChannelFailed})!Listener {
        const gate = try accept_gate.Gate.open();
        errdefer gate.deinit();
        return .{
            .server = try listenExclusiveReuseAddr(io, address),
            .io = io,
            .gate = gate,
        };
    }

    /// `IpAddress.listen` with `SO_REUSEADDR` alone. Zig's `reuse_address`
    /// option enables both SO_REUSEADDR and SO_REUSEPORT on POSIX, and port
    /// sharing is a load-balancer policy, not a safe default for an
    /// identity-bearing OCapN listener: two Hosts on one address would make
    /// the kernel choose which peer a dial reaches. So the IPv4 path builds
    /// the listener through `socket.openListenerReuseAddr`, taking the
    /// restart contract that helper documents without the port sharing.
    /// IPv6 and non-POSIX targets keep the plain std listen, with the
    /// TIME_WAIT restart behavior. Nothing in this tree binds a blocking IPv6
    /// listener today, and that boundary stays visible instead of being papered
    /// over with untested sockaddr packing.
    fn listenExclusiveReuseAddr(io: std.Io, address: IpAddress) IpAddress.ListenError!Server {
        const os: socket.Os = switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .darwin,
            else => return IpAddress.listen(&address, io, .{}),
        };
        switch (address) {
            .ip6 => return IpAddress.listen(&address, io, .{}),
            .ip4 => |ip4| {
                const bound = socket.openListenerReuseAddr(
                    os,
                    .{ .bytes = ip4.bytes, .port = ip4.port },
                    std.Io.net.default_kernel_backlog,
                ) catch |err| return switch (err) {
                    // The one refusal a pinned-port restart acts on keeps its
                    // name; the rest of the raw-socket set collapses to the
                    // std vocabulary this signature already speaks.
                    error.AddressInUse => error.AddressInUse,
                    else => error.SystemResources,
                };
                return .{
                    .socket = .{
                        .handle = bound.fd,
                        .address = .{ .ip4 = .{ .bytes = ip4.bytes, .port = bound.port } },
                    },
                    .options = {},
                };
            },
        }
    }

    pub fn localAddress(self: *const Listener) IpAddress {
        return self.server.socket.address;
    }

    pub fn readinessFd(self: *const Listener) Socket.Handle {
        return self.server.socket.handle;
    }

    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) WaitError!bool {
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
        return self.gate.waitReadable(self.server.socket.handle, timeout_ms);
    }

    pub fn accept(
        self: *Listener,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) AcceptError!Connection {
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        return Connection.over(self.io, stream, read_buf, write_buf, options) catch |err| {
            stream.close(self.io);
            return err;
        };
    }

    pub fn acceptStream(self: *Listener, options: StreamOptions) AcceptError!Stream {
        self.gate.lock(self.io);
        defer self.gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        configureStream(stream, options) catch |err| {
            stream.close(self.io);
            return err;
        };
        return stream;
    }

    /// Accept under the gate's lease. The caller holds it through wrapper
    /// construction so a concurrent deinit cannot free listener state between
    /// the kernel accept and the last read of `self.io`.
    fn acceptStreamLocked(self: *Listener) WaitError!Stream {
        if (!try self.gate.waitReadable(self.server.socket.handle, -1)) return error.ConnectionLost;
        return self.server.accept(self.io) catch error.ConnectionLost;
    }

    pub fn shutdown(self: *Listener) void {
        self.gate.shutdown();
    }

    pub fn deinit(self: *Listener) void {
        self.gate.shutdown();
        self.gate.join(self.io);
        self.server.deinit(self.io);
        self.gate.deinit();
    }
};
