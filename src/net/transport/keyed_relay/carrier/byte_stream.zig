//! Private byte-stream waist below the relay's RFC 6455 state machine.
//!
//! A carrier channel owns one pinned implementation. WebSocket owns framing;
//! clear TCP and TLS own only ordered bytes, readiness, and destruction. The
//! nonblocking operations are explicit because a TLS read can require a socket
//! write and a TLS write can require a socket read.

const std = @import("std");

const foundation = @import("foundation");
const multiplexed_resident = @import("../../../multiplexed_resident.zig");
const poll = @import("../../../poll.zig");
const socket = @import("../../../socket.zig");
const tls_stream = @import("../../../tls/pollable_stream.zig");

const Io = std.Io;

pub const Fill = enum { progress, would_block, closed };
pub const Shutdown = enum { complete, wait_read, wait_write };

pub const Stream = struct {
    ctx: *anyopaque,
    reader: *Io.Reader,
    writer: *Io.Writer,
    vtable: *const VTable,

    pub const VTable = struct {
        socket_handle: *const fn (*anyopaque) Io.net.Socket.Handle,
        try_fill: *const fn (*anyopaque) error{ReadFailed}!Fill,
        try_flush: *const fn (*anyopaque) isize,
        has_pending_write: *const fn (*anyopaque) bool,
        try_shutdown: *const fn (*anyopaque) error{ ReadFailed, WriteFailed }!Shutdown,
        take_failure: *const fn (*anyopaque) ?foundation.FailureChain,
        deinit_outcome: *const fn (*anyopaque) ?foundation.FailureChain,
    };

    pub fn socketHandle(self: Stream) Io.net.Socket.Handle {
        return self.vtable.socket_handle(self.ctx);
    }

    pub fn tryFill(self: Stream) error{ReadFailed}!Fill {
        return self.vtable.try_fill(self.ctx);
    }

    pub fn tryFlush(self: Stream) isize {
        return self.vtable.try_flush(self.ctx);
    }

    pub fn hasPendingWrite(self: Stream) bool {
        return self.vtable.has_pending_write(self.ctx);
    }

    pub fn tryShutdown(self: Stream) error{ ReadFailed, WriteFailed }!Shutdown {
        return self.vtable.try_shutdown(self.ctx);
    }

    pub fn takeFailure(self: Stream) ?foundation.FailureChain {
        return self.vtable.take_failure(self.ctx);
    }

    pub fn deinitOutcome(self: *Stream) ?foundation.FailureChain {
        const failure = self.vtable.deinit_outcome(self.ctx);
        self.* = undefined;
        return failure;
    }
};

const clear_buffer_bytes = 2048;

const Clear = struct {
    allocator: std.mem.Allocator,
    io: Io,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    failure: ?foundation.FailureChain = null,
    read_store: [clear_buffer_bytes]u8,
    write_store: [clear_buffer_bytes]u8,

    fn create(allocator: std.mem.Allocator, io: Io, raw: Io.net.Stream) !*Clear {
        const self = try allocator.create(Clear);
        self.allocator = allocator;
        self.io = io;
        self.failure = null;
        self.reader = raw.reader(io, &self.read_store);
        self.writer = raw.writer(io, &self.write_store);
        return self;
    }

    fn note(self: *Clear, cause: anyerror) void {
        if (self.failure) |*failure| failure.note(cause) else self.failure = .init(cause);
    }

    fn socketHandle(raw: *anyopaque) Io.net.Socket.Handle {
        const self: *Clear = @ptrCast(@alignCast(raw));
        return self.reader.stream.socket.handle;
    }

    fn tryFill(raw: *anyopaque) error{ReadFailed}!Fill {
        const self: *Clear = @ptrCast(@alignCast(raw));
        var fds = [_]std.posix.pollfd{.{
            .fd = self.reader.stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = poll.wait(&fds, 0) catch |err| {
            self.note(err);
            return error.ReadFailed;
        };
        if (ready == 0) return .would_block;
        if (fds[0].revents & std.posix.POLL.NVAL != 0) {
            self.note(error.InvalidSocket);
            return error.ReadFailed;
        }
        self.reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => return .closed,
            error.ReadFailed => {
                self.note(self.reader.err orelse err);
                return error.ReadFailed;
            },
        };
        return .progress;
    }

    fn tryFlush(raw: *anyopaque) isize {
        const self: *Clear = @ptrCast(@alignCast(raw));
        const writer = &self.writer.interface;
        if (writer.end == 0) return 0;
        const n = socket.sendNonblocking(
            self.reader.stream.socket.handle,
            writer.buffer[0..writer.end],
        ) catch |err| return switch (err) {
            error.WouldBlock => multiplexed_resident.would_block,
            error.SendFailed => blk: {
                self.note(err);
                break :blk -1;
            },
        };
        const remaining = writer.end - n;
        std.mem.copyForwards(u8, writer.buffer[0..remaining], writer.buffer[n..writer.end]);
        writer.end = remaining;
        return @intCast(n);
    }

    fn hasPendingWrite(raw: *anyopaque) bool {
        const self: *Clear = @ptrCast(@alignCast(raw));
        return self.writer.interface.end != 0;
    }

    fn tryShutdown(_: *anyopaque) error{ ReadFailed, WriteFailed }!Shutdown {
        return .complete;
    }

    fn deinitOutcome(raw: *anyopaque) ?foundation.FailureChain {
        const self: *Clear = @ptrCast(@alignCast(raw));
        const allocator = self.allocator;
        // Interface errors are harvested by `takeFailure` at the operation
        // that observed them. Destruction itself is abortive; a cancellation
        // used to stop a parked registration is not a cleanup failure.
        const failure = self.failure;
        self.reader.stream.close(self.io);
        allocator.destroy(self);
        return failure;
    }

    fn takeFailure(self: *Clear) ?foundation.FailureChain {
        if (self.reader.err) |cause| self.note(cause);
        if (self.writer.err) |cause| self.note(cause);
        if (self.writer.write_file_err) |cause| self.note(cause);
        const failure = self.failure;
        self.failure = null;
        return failure;
    }

    fn takeFailureErased(raw: *anyopaque) ?foundation.FailureChain {
        const self: *Clear = @ptrCast(@alignCast(raw));
        return self.takeFailure();
    }
};

const clear_vtable: Stream.VTable = .{
    .socket_handle = Clear.socketHandle,
    .try_fill = Clear.tryFill,
    .try_flush = Clear.tryFlush,
    .has_pending_write = Clear.hasPendingWrite,
    .try_shutdown = Clear.tryShutdown,
    .take_failure = Clear.takeFailureErased,
    .deinit_outcome = Clear.deinitOutcome,
};

/// Adopt a connected TCP socket. On refusal the caller still owns `raw`.
pub fn adoptClear(
    allocator: std.mem.Allocator,
    io: Io,
    raw: Io.net.Stream,
) std.mem.Allocator.Error!Stream {
    const clear = try Clear.create(allocator, io, raw);
    return .{
        .ctx = clear,
        .reader = &clear.reader.interface,
        .writer = &clear.writer.interface,
        .vtable = &clear_vtable,
    };
}

const secure_vtable: Stream.VTable = .{
    .socket_handle = secureSocketHandle,
    .try_fill = secureTryFill,
    .try_flush = secureTryFlush,
    .has_pending_write = secureHasPendingWrite,
    .try_shutdown = secureTryShutdown,
    .take_failure = secureTakeFailure,
    .deinit_outcome = secureDeinitOutcome,
};

/// Adopt an established TLS stream. The caller retains ownership on no path:
/// this projection is allocation-free and always transfers the pin.
pub fn adoptSecure(secure: *tls_stream.Stream) Stream {
    return .{
        .ctx = secure,
        .reader = &secure.reader.interface,
        .writer = &secure.writer.interface,
        .vtable = &secure_vtable,
    };
}

fn secureSocketHandle(raw: *anyopaque) Io.net.Socket.Handle {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    return secure.socketHandle();
}

fn secureTryFill(raw: *anyopaque) error{ReadFailed}!Fill {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    return switch (secure.tryFill() catch return error.ReadFailed) {
        .progress => .progress,
        .would_block => .would_block,
        .closed => .closed,
    };
}

fn secureTryFlush(raw: *anyopaque) isize {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    const result = secure.tryFlush();
    return if (result == -2) multiplexed_resident.would_block else result;
}

fn secureHasPendingWrite(raw: *anyopaque) bool {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    return secure.hasPendingWrite();
}

fn secureTryShutdown(raw: *anyopaque) error{ ReadFailed, WriteFailed }!Shutdown {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    return switch (try secure.tryShutdown()) {
        .complete => .complete,
        .wait_read => .wait_read,
        .wait_write => .wait_write,
    };
}

fn secureTakeFailure(raw: *anyopaque) ?foundation.FailureChain {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    const failure = secure.takeFailure() orelse return null;
    return failure.chain;
}

fn secureDeinitOutcome(raw: *anyopaque) ?foundation.FailureChain {
    const secure: *tls_stream.Stream = @ptrCast(@alignCast(raw));
    const failure = secure.deinitOutcome() orelse return null;
    return failure.chain;
}
