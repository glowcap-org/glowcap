//! Raw TCP socket realization shared by every TCP profile and projection.
//!
//! This module owns the one transition from `std.Io` to TCP sockets: dialing,
//! binding, accepting, stream tuning, readiness, byte I/O, and close. OCapN
//! locator/profile semantics stay in the sibling adapters; engine connections
//! and C callbacks both project this same runtime instead of reimplementing it.

const std = @import("std");

const poll = @import("../poll.zig");
const socket = @import("../socket.zig");
const wake_channel = @import("../wake_channel.zig");

const IpAddress = std.Io.net.IpAddress;
const Socket = std.Io.net.Socket;
const Stream = std.Io.net.Stream;
const Server = std.Io.net.Server;

pub const Keepalive = socket.Keepalive;
pub const ConfigurationError = socket.ConfigurationError;
pub const WaitError = error{ ConnectionLost, WakeNudgeFailed, WakeDrainFailed };
pub const AcceptError = WaitError || ConfigurationError;

pub const StreamOptions = struct {
    keepalive: ?Keepalive = null,
};

fn configureStream(stream: Stream, options: StreamOptions) ConfigurationError!void {
    try std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    );
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
/// wait through a private wake descriptor; deinit joins that operation before
/// releasing storage.
pub const Listener = struct {
    server: Server,
    io: std.Io,
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn bind(io: std.Io, address: IpAddress) (IpAddress.ListenError || error{WakeChannelFailed})!Listener {
        const wake = try wake_channel.WakeChannel.open();
        errdefer wake.deinit();
        return .{
            .server = try IpAddress.listen(&address, io, .{ .reuse_address = true }),
            .io = io,
            .wake = wake,
        };
    }

    pub fn localAddress(self: *const Listener) IpAddress {
        return self.server.socket.address;
    }

    pub fn readinessFd(self: *const Listener) Socket.Handle {
        return self.server.socket.handle;
    }

    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) WaitError!bool {
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        try self.wake_failure.check();
        if (self.stopping.load(.acquire)) return error.ConnectionLost;
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake.read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = poll.wait(&fds, timeout_ms) catch return error.ConnectionLost;
        try self.wake_failure.check();
        if (self.stopping.load(.acquire) or
            fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        {
            self.wake.drain() catch |err| {
                self.wake_failure.record(err);
                return err;
            };
            return error.ConnectionLost;
        }
        return ready != 0 and
            fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
    }

    pub fn accept(
        self: *Listener,
        read_buf: []u8,
        write_buf: []u8,
        options: StreamOptions,
    ) AcceptError!Connection {
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        return Connection.over(self.io, stream, read_buf, write_buf, options) catch |err| {
            stream.close(self.io);
            return err;
        };
    }

    pub fn acceptStream(self: *Listener, options: StreamOptions) AcceptError!Stream {
        self.operation_gate.lockUncancelable(self.io);
        defer self.operation_gate.unlock(self.io);
        const stream = try self.acceptStreamLocked();
        configureStream(stream, options) catch |err| {
            stream.close(self.io);
            return err;
        };
        return stream;
    }

    fn acceptStreamLocked(self: *Listener) WaitError!Stream {
        try self.wake_failure.check();
        if (self.stopping.load(.acquire)) return error.ConnectionLost;
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake.read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = poll.wait(&fds, -1) catch return error.ConnectionLost;
        try self.wake_failure.check();
        if (ready == 0 or self.stopping.load(.acquire) or
            fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        {
            self.wake.drain() catch |err| {
                self.wake_failure.record(err);
                return err;
            };
            return error.ConnectionLost;
        }
        return self.server.accept(self.io) catch error.ConnectionLost;
    }

    pub fn shutdown(self: *Listener) void {
        self.stopping.store(true, .release);
        _ = self.wake.nudge() catch |err| self.wake_failure.record(err);
    }

    pub fn deinit(self: *Listener) void {
        self.shutdown();
        self.operation_gate.lockUncancelable(self.io);
        self.operation_gate.unlock(self.io);
        self.server.deinit(self.io);
        self.wake.deinit();
    }
};
