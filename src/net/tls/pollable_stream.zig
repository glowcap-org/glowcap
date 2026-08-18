//! Pollable socket driver for the transport-neutral client TLS engine.
//!
//! This is the byte transform between TCP and an upper protocol such as
//! WebSocket. It owns fixed ciphertext buffers, drives bidirectional engine
//! interest, and exposes ordinary plaintext Reader/Writer interfaces. No TLS
//! engine or upper protocol owns socket polling.

const std = @import("std");
const engine = @import("engine.zig");
const transform = @import("transform.zig");

const foundation = @import("foundation");
const poll = @import("../poll.zig");
const socket = @import("../socket.zig");
const stream_shim = @import("../stream_shim.zig");

const Io = std.Io;
const plaintext_buffer_bytes = 2048;
const wait_slice_ms: i32 = 50;

pub const EstablishError = error{ TlsFailed, TimedOut, Cancelled };
pub const TryError = error{ ReadFailed, WriteFailed };
pub const TryProgress = enum { progress, would_block, closed };
pub const ShutdownProgress = enum { complete, wait_read, wait_write };

const Source = struct {
    stream: *Stream,

    pub fn readSome(self: Source, dest: []u8) Io.Reader.Error!usize {
        return self.stream.readSome(dest);
    }

    pub fn writeAll(self: Source, bytes: []const u8) Io.Writer.Error!void {
        return self.stream.writeAll(bytes);
    }

    pub fn flush(self: Source) Io.Writer.Error!void {
        self.stream.drainCipherBlocking(.transmit) catch return error.WriteFailed;
    }
};

const Shim = stream_shim.Shim(Source);

pub const Stream = struct {
    allocator: std.mem.Allocator,
    io: Io,
    raw_reader: Io.net.Stream.Reader,
    raw_writer: Io.net.Stream.Writer,
    transform: transform.Transform,
    reader: Shim.Reader,
    writer: Shim.Writer,
    established: bool = false,
    peer_closed: bool = false,
    shutdown_complete: bool = false,
    raw_read_store: [plaintext_buffer_bytes]u8,
    raw_write_store: [plaintext_buffer_bytes]u8,
    plain_read_store: [plaintext_buffer_bytes]u8,
    plain_write_store: [plaintext_buffer_bytes]u8,

    /// Pin an engine over an already-connected socket. This adopts both. The
    /// engine runtime, if any, remains owned through the engine's own lease.
    pub fn create(
        allocator: std.mem.Allocator,
        io: Io,
        raw: Io.net.Stream,
        client: engine.Client,
    ) std.mem.Allocator.Error!*Stream {
        const self = try allocator.create(Stream);
        self.allocator = allocator;
        self.io = io;
        self.transform = .init(client);
        self.established = false;
        self.peer_closed = false;
        self.shutdown_complete = false;
        self.raw_reader = raw.reader(io, &self.raw_read_store);
        self.raw_writer = raw.writer(io, &self.raw_write_store);
        self.reader = Shim.Reader.init(.{ .stream = self }, &self.plain_read_store);
        self.writer = Shim.Writer.init(.{ .stream = self }, &self.plain_write_store);
        return self;
    }

    pub fn socketHandle(self: *const Stream) Io.net.Socket.Handle {
        return self.raw_reader.stream.socket.handle;
    }

    /// Complete the client handshake within the caller's absolute monotonic
    /// deadline. Cancellation and timeout remain policy classifications at the
    /// carrier seam; the TLS owner retains only exact transport/TLS causes.
    pub fn establish(
        self: *Stream,
        deadline_ms: i64,
        stop_requested: ?*const std.atomic.Value(bool),
    ) EstablishError!void {
        while (!self.established) {
            if (cancelled(stop_requested)) return error.Cancelled;
            try self.drainCipherUntil(deadline_ms, stop_requested);
            const transition = self.drive(.handshake, &.{}, &.{}) catch return error.TlsFailed;
            try self.drainCipherUntil(deadline_ms, stop_requested);
            if (transition.status == .established) {
                self.established = true;
                return;
            }
            if (transition.interest.read or !transition.transfer.any())
                try self.fillCipherUntil(deadline_ms, stop_requested);
        }
    }

    pub fn readSome(self: *Stream, dest: []u8) Io.Reader.Error!usize {
        if (dest.len == 0) return 0;
        while (true) {
            if (self.peer_closed) return error.EndOfStream;
            self.drainCipherBlocking(.receive) catch return error.ReadFailed;
            const transition = self.drive(.receive, &.{}, dest) catch return error.ReadFailed;
            self.drainCipherBlocking(.receive) catch return error.ReadFailed;
            if (transition.transfer.plaintext_produced != 0)
                return transition.transfer.plaintext_produced;
            if (transition.status == .clean_close) {
                self.peer_closed = true;
                return error.EndOfStream;
            }
            if (transition.interest.read or !transition.transfer.any())
                self.fillCipherBlocking(.receive) catch return error.ReadFailed;
        }
    }

    pub fn writeAll(self: *Stream, bytes: []const u8) Io.Writer.Error!void {
        var remaining = bytes;
        while (remaining.len != 0) {
            self.drainCipherBlocking(.transmit) catch return error.WriteFailed;
            const transition = self.drive(.transmit, remaining, &.{}) catch return error.WriteFailed;
            remaining = remaining[transition.transfer.plaintext_consumed..];
            self.drainCipherBlocking(.transmit) catch return error.WriteFailed;
            if (transition.interest.read and transition.transfer.plaintext_consumed == 0)
                self.fillCipherBlocking(.transmit) catch return error.WriteFailed;
            if (!transition.transfer.any() and !transition.interest.any()) {
                self.note(.transmit, error.TlsNoProgress);
                return error.WriteFailed;
            }
        }
    }

    /// Fill the plaintext reader without parking the reactor.
    pub fn tryFill(self: *Stream) TryError!TryProgress {
        if (self.peer_closed) return .closed;
        const reader = &self.reader.interface;
        if (reader.end == reader.buffer.len and reader.seek != 0) {
            const buffered = reader.buffered();
            std.mem.copyForwards(u8, reader.buffer[0..buffered.len], buffered);
            reader.seek = 0;
            reader.end = buffered.len;
        }
        if (reader.end == reader.buffer.len) {
            self.note(.receive, error.TlsPlaintextBufferFull);
            return error.ReadFailed;
        }
        const dest = reader.buffer[reader.end..];
        var spins: usize = 0;
        while (spins < 8) : (spins += 1) {
            const drained = try self.tryDrainCipher();
            if (drained == .failed) return error.ReadFailed;
            const transition = self.drive(.receive, &.{}, dest) catch return error.ReadFailed;
            if (transition.transfer.plaintext_produced != 0) {
                reader.end += transition.transfer.plaintext_produced;
                return .progress;
            }
            if (transition.status == .clean_close) {
                self.peer_closed = true;
                return .closed;
            }
            if (transition.interest.read or !transition.transfer.any()) switch (try self.tryFillCipher(.receive)) {
                .progress => continue,
                .would_block => return .would_block,
                .closed => return error.ReadFailed,
            };
        }
        return .would_block;
    }

    /// Flush owned plaintext/ciphertext without parking. The return is the
    /// plaintext prefix consumed from the public writer; ciphertext may remain
    /// internally pending for the next writable edge.
    pub fn tryFlush(self: *Stream) isize {
        const drained = self.tryDrainCipher() catch return -1;
        if (drained == .would_block) return -2;
        const writer = &self.writer.interface;
        if (writer.end == 0) return 0;
        const transition = self.drive(.transmit, writer.buffer[0..writer.end], &.{}) catch return -1;
        const consumed = transition.transfer.plaintext_consumed;
        if (consumed != 0) {
            const remaining = writer.end - consumed;
            std.mem.copyForwards(u8, writer.buffer[0..remaining], writer.buffer[consumed..writer.end]);
            writer.end = remaining;
        }
        _ = self.tryDrainCipher() catch return -1;
        if (consumed != 0) return @intCast(consumed);
        return -2;
    }

    pub fn hasPendingWrite(self: *const Stream) bool {
        return self.writer.interface.end != 0 or self.transform.pendingCiphertext().len != 0;
    }

    /// Advance the authenticated TLS close without parking the caller. The
    /// enclosing carrier reactor owns readiness and the close deadline; this
    /// method owns only engine and socket progress.
    pub fn tryShutdown(self: *Stream) TryError!ShutdownProgress {
        if (self.shutdown_complete) return .complete;
        var spins: usize = 0;
        while (spins < 8) : (spins += 1) {
            switch (try self.tryDrainCipher()) {
                .progress => {},
                .would_block => return .wait_write,
                .failed => return error.WriteFailed,
            }
            if (self.transform.pendingCiphertext().len != 0) continue;
            if (self.shutdown_complete) return .complete;

            const transition = self.drive(.shutdown, &.{}, &.{}) catch return error.WriteFailed;
            if (transition.status == .clean_close) self.shutdown_complete = true;
            if (self.transform.pendingCiphertext().len != 0) continue;
            if (self.shutdown_complete) return .complete;
            if (transition.interest.read) switch (try self.tryFillCipher(.shutdown)) {
                .progress => continue,
                .would_block => return .wait_read,
                .closed => return error.ReadFailed,
            };
            if (!transition.transfer.any()) {
                if (transition.interest.write) return .wait_write;
                self.note(.shutdown, error.TlsNoProgress);
                return error.WriteFailed;
            }
        }
        self.note(.shutdown, error.TlsNoProgress);
        return error.WriteFailed;
    }

    pub fn takeFailure(self: *Stream) ?engine.Failure {
        return self.transform.takeFailure();
    }

    /// Abortive destruction never performs network I/O. An explicit carrier
    /// close barrier will drive close_notify before reaching this fallback.
    pub fn deinitOutcome(self: *Stream) ?engine.Failure {
        const failure = self.transform.deinitOutcome();
        const allocator = self.allocator;
        self.raw_reader.stream.close(self.io);
        allocator.destroy(self);
        return failure;
    }

    fn drive(
        self: *Stream,
        phase: engine.Phase,
        plaintext_in: []const u8,
        plaintext_out: []u8,
    ) error{TlsFailed}!engine.Step {
        return self.transform.step(phase, plaintext_in, plaintext_out);
    }

    const Drain = enum { progress, would_block, failed };

    fn tryDrainCipher(self: *Stream) TryError!Drain {
        const pending = self.transform.pendingCiphertext();
        if (pending.len == 0) return .progress;
        const count = socket.sendNonblocking(self.socketHandle(), pending) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            error.SendFailed => {
                self.note(.transmit, err);
                return error.WriteFailed;
            },
        };
        self.transform.consumeCiphertext(.transmit, count) catch return error.WriteFailed;
        return .progress;
    }

    fn drainCipherBlocking(self: *Stream, phase: engine.Phase) error{WriteFailed}!void {
        const pending = self.transform.pendingCiphertext();
        if (pending.len == 0) return;
        self.raw_writer.interface.writeAll(pending) catch |err| {
            self.note(phase, self.raw_writer.err orelse err);
            return error.WriteFailed;
        };
        self.raw_writer.interface.flush() catch |err| {
            self.note(phase, self.raw_writer.err orelse err);
            return error.WriteFailed;
        };
        self.transform.consumeCiphertext(phase, pending.len) catch return error.WriteFailed;
    }

    fn fillCipherBlocking(self: *Stream, phase: engine.Phase) error{ReadFailed}!void {
        const dest = self.transform.ciphertextDestination(phase) catch return error.ReadFailed;
        var slices = [_][]u8{dest};
        const count = self.raw_reader.interface.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => {
                self.transform.noteTransportEof(phase);
                return error.ReadFailed;
            },
            error.ReadFailed => {
                self.note(phase, self.raw_reader.err orelse err);
                return error.ReadFailed;
            },
        };
        std.debug.assert(count != 0);
        self.transform.commitCiphertext(phase, count) catch return error.ReadFailed;
    }

    fn tryFillCipher(self: *Stream, phase: engine.Phase) TryError!TryProgress {
        const dest = self.transform.ciphertextDestination(phase) catch return error.ReadFailed;
        const count = socket.receiveNonblocking(self.socketHandle(), dest) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            error.ReceiveFailed => {
                self.note(phase, err);
                return error.ReadFailed;
            },
        };
        if (count == 0) {
            self.transform.noteTransportEof(phase);
            return .closed;
        }
        self.transform.commitCiphertext(phase, count) catch return error.ReadFailed;
        return .progress;
    }

    fn drainCipherUntil(
        self: *Stream,
        deadline_ms: i64,
        stop_requested: ?*const std.atomic.Value(bool),
    ) EstablishError!void {
        while (self.transform.pendingCiphertext().len != 0) switch (self.tryDrainCipher() catch return error.TlsFailed) {
            .progress => {},
            .failed => return error.TlsFailed,
            .would_block => try self.waitUntil(std.posix.POLL.OUT, deadline_ms, stop_requested),
        };
    }

    fn fillCipherUntil(
        self: *Stream,
        deadline_ms: i64,
        stop_requested: ?*const std.atomic.Value(bool),
    ) EstablishError!void {
        while (true) switch (self.tryFillCipher(.handshake) catch return error.TlsFailed) {
            .progress => return,
            .closed => return error.TlsFailed,
            .would_block => try self.waitUntil(std.posix.POLL.IN, deadline_ms, stop_requested),
        };
    }

    fn waitUntil(
        self: *Stream,
        events: i16,
        deadline_ms: i64,
        stop_requested: ?*const std.atomic.Value(bool),
    ) EstablishError!void {
        if (cancelled(stop_requested)) return error.Cancelled;
        const remaining = deadline_ms - @import("../clock.zig").nowMs(self.io);
        if (remaining <= 0) return error.TimedOut;
        var fds = [_]std.posix.pollfd{.{ .fd = self.socketHandle(), .events = events, .revents = 0 }};
        const timeout: i32 = @intCast(@min(remaining, @as(i64, wait_slice_ms)));
        const ready = poll.wait(&fds, timeout) catch |err| {
            self.note(.handshake, err);
            return error.TlsFailed;
        };
        if (ready == 0) return;
        if (fds[0].revents & std.posix.POLL.NVAL != 0) {
            self.note(.handshake, error.InvalidSocket);
            return error.TlsFailed;
        }
    }

    fn note(self: *Stream, phase: engine.Phase, cause: anyerror) void {
        self.transform.note(phase, cause);
    }
};

/// Fixed state allocated for one pollable TLS channel. This includes both
/// record windows and four 2 KiB socket/plaintext buffers, but excludes the
/// engine's separately measured dynamic client state.
pub const connection_state_bytes = @sizeOf(Stream);

fn cancelled(stop_requested: ?*const std.atomic.Value(bool)) bool {
    const stop = stop_requested orelse return false;
    return stop.load(.acquire);
}
