//! Deterministic socket-driver evidence for the generic TLS transform.

const std = @import("std");
const glowcap = @import("glowcap");

const tls = glowcap.net.tls.engine;
const PollableStream = glowcap.net.tls.pollable_stream.Stream;
const record_bytes = 18 * 1024;

fn writeAllNonblocking(io: std.Io, fd: std.c.fd_t, bytes: []const u8) !void {
    const deadline = glowcap.net.clock.nowMs(io) + 1_000;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.send(fd, bytes[offset..].ptr, bytes.len - offset, 0);
        if (rc < 0) switch (std.c.errno(rc)) {
            .AGAIN => {
                if (glowcap.net.clock.nowMs(io) >= deadline) return error.WriteTimedOut;
                try std.Io.sleep(io, .fromMilliseconds(1), .real);
                continue;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        };
        const written: usize = @intCast(rc);
        if (written == 0) return error.WriteZero;
        offset += written;
    }
}

fn setSocketBuffer(fd: std.c.fd_t, opt: u32, bytes: c_int) !void {
    var value = bytes;
    const rc = std.c.setsockopt(fd, std.c.SOL.SOCKET, opt, &value, @sizeOf(c_int));
    if (rc != 0) return error.SocketBufferSetupFailed;
}

test "pollable TLS connection state has a measured footprint" {
    try std.testing.expectEqual(
        @as(usize, 45_656),
        glowcap.net.tls.pollable_stream.connection_state_bytes,
    );
}

const IdentityEngine = struct {
    deinit_count: usize = 0,

    fn client(self: *IdentityEngine) tls.Client {
        return .init(self, &vtable);
    }

    fn step(_: *anyopaque, phase: tls.Phase, exchange: tls.Exchange) tls.RawOutcome {
        return switch (phase) {
            .handshake => .{ .stepped = .{ .status = .established } },
            .transmit => blk: {
                const count = @min(exchange.plaintext_in.len, exchange.ciphertext_out.len);
                @memcpy(exchange.ciphertext_out[0..count], exchange.plaintext_in[0..count]);
                break :blk .{ .stepped = .{ .transfer = .{
                    .plaintext_consumed = count,
                    .ciphertext_produced = count,
                } } };
            },
            .receive => if (exchange.ciphertext_in.len == 0)
                .{ .stepped = .{ .interest = .{ .read = true } } }
            else blk: {
                const count = @min(exchange.ciphertext_in.len, exchange.plaintext_out.len);
                @memcpy(exchange.plaintext_out[0..count], exchange.ciphertext_in[0..count]);
                break :blk .{ .stepped = .{ .transfer = .{
                    .ciphertext_consumed = count,
                    .plaintext_produced = count,
                } } };
            },
            .shutdown => .{ .stepped = .{ .status = .clean_close } },
        };
    }

    fn deinit(raw: *anyopaque) ?glowcap.foundation.FailureChain {
        const self: *IdentityEngine = @ptrCast(@alignCast(raw));
        self.deinit_count += 1;
        return null;
    }

    const vtable: tls.VTable = .{ .step = step, .deinit = deinit };
};

const FragmentedRecordEngine = struct {
    receive_count: usize = 0,

    fn client(self: *FragmentedRecordEngine) tls.Client {
        return .init(self, &vtable);
    }

    fn step(raw: *anyopaque, phase: tls.Phase, exchange: tls.Exchange) tls.RawOutcome {
        const self: *FragmentedRecordEngine = @ptrCast(@alignCast(raw));
        return switch (phase) {
            .handshake => .{ .stepped = .{ .status = .established } },
            .receive => switch (self.receive_count) {
                0 => first: {
                    if (exchange.ciphertext_in.len == 0)
                        break :first .{ .stepped = .{ .interest = .{ .read = true } } };
                    self.receive_count = 1;
                    break :first .{ .stepped = .{
                        .interest = .{ .read = true },
                        .transfer = .{ .ciphertext_consumed = 1 },
                    } };
                },
                else => done: {
                    exchange.plaintext_out[0] = exchange.ciphertext_in[exchange.ciphertext_in.len - 1];
                    break :done .{ .stepped = .{ .transfer = .{
                        .ciphertext_consumed = exchange.ciphertext_in.len,
                        .plaintext_produced = 1,
                    } } };
                },
            },
            .transmit => unreachable,
            .shutdown => .{ .stepped = .{ .status = .clean_close } },
        };
    }

    fn deinit(_: *anyopaque) ?glowcap.foundation.FailureChain {
        return null;
    }

    const vtable: tls.VTable = .{ .step = step, .deinit = deinit };
};

const WaitingHandshakeEngine = struct {
    deinit_count: usize = 0,

    fn client(self: *WaitingHandshakeEngine) tls.Client {
        return .init(self, &vtable);
    }

    fn step(_: *anyopaque, phase: tls.Phase, _: tls.Exchange) tls.RawOutcome {
        return switch (phase) {
            .handshake => .{ .stepped = .{ .interest = .{ .read = true } } },
            else => unreachable,
        };
    }

    fn deinit(raw: *anyopaque) ?glowcap.foundation.FailureChain {
        const self: *WaitingHandshakeEngine = @ptrCast(@alignCast(raw));
        self.deinit_count += 1;
        return null;
    }

    const vtable: tls.VTable = .{ .step = step, .deinit = deinit };
};

fn waitingStream(fake: *WaitingHandshakeEngine) !struct {
    stream: *PollableStream,
    peer: std.Io.net.Stream,
} {
    const pair = try glowcap.net.wake_channel.WakeChannel.open();
    const raw: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.read,
        .address = undefined,
    } };
    return .{
        .stream = try PollableStream.create(
            std.testing.allocator,
            std.testing.io,
            raw,
            fake.client(),
        ),
        .peer = .{ .socket = .{
            .handle = pair.write,
            .address = undefined,
        } },
    };
}

test "pollable TLS cancellation stops a pending handshake without inventing a TLS failure" {
    var fake = WaitingHandshakeEngine{};
    const pair = try waitingStream(&fake);
    defer pair.peer.close(std.testing.io);
    var stop: std.atomic.Value(bool) = .init(true);

    try std.testing.expectError(
        error.Cancelled,
        pair.stream.establish(glowcap.net.clock.nowMs(std.testing.io) + 1_000, &stop),
    );
    try std.testing.expectEqual(@as(?tls.Failure, null), pair.stream.takeFailure());
    try std.testing.expectEqual(@as(?tls.Failure, null), pair.stream.deinitOutcome());
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_count);
}

test "pollable TLS timeout stops a pending handshake without consuming the channel" {
    var fake = WaitingHandshakeEngine{};
    const pair = try waitingStream(&fake);
    defer pair.peer.close(std.testing.io);

    try std.testing.expectError(
        error.TimedOut,
        pair.stream.establish(glowcap.net.clock.nowMs(std.testing.io), null),
    );
    try std.testing.expectEqual(@as(?tls.Failure, null), pair.stream.takeFailure());
    try std.testing.expectEqual(@as(?tls.Failure, null), pair.stream.deinitOutcome());
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_count);
}

test "pollable TLS owns bidirectional bytes and reports truncation once" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pair = try glowcap.net.wake_channel.WakeChannel.open();
    const raw: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.read,
        .address = undefined,
    } };
    const peer: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.write,
        .address = undefined,
    } };
    defer peer.close(io);
    var peer_read_store: [32]u8 = undefined;
    var peer_reader = peer.reader(io, &peer_read_store);

    var fake = IdentityEngine{};
    const stream = try PollableStream.create(allocator, io, raw, fake.client());
    try stream.establish(glowcap.net.clock.nowMs(io) + 1_000, null);

    try stream.writer.interface.writeAll("outbound");
    try stream.writer.interface.flush();
    var observed: [8]u8 = undefined;
    try peer_reader.interface.readSliceAll(&observed);
    try std.testing.expectEqualStrings("outbound", &observed);

    try writeAllNonblocking(io, pair.write, "inbound");
    try std.testing.expectEqual(
        glowcap.net.tls.pollable_stream.TryProgress.progress,
        try stream.tryFill(),
    );
    var plaintext: [7]u8 = undefined;
    try stream.reader.interface.readSliceAll(&plaintext);
    try std.testing.expectEqualStrings("inbound", &plaintext);

    try peer.shutdown(io, .both);
    try std.testing.expectError(error.ReadFailed, stream.tryFill());
    const failure = stream.takeFailure().?;
    try std.testing.expectEqualStrings("TlsTruncated", failure.chain.primaryName());
    try std.testing.expectEqual(@as(?tls.Failure, null), stream.takeFailure());
    try std.testing.expectEqual(@as(?tls.Failure, null), stream.deinitOutcome());
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_count);
}

test "pollable TLS blocking read advances on one available ciphertext prefix" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pair = try glowcap.net.wake_channel.WakeChannel.open();
    const raw: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.read,
        .address = undefined,
    } };
    const peer: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.write,
        .address = undefined,
    } };
    defer peer.close(io);
    var fake = IdentityEngine{};
    const stream = try PollableStream.create(allocator, io, raw, fake.client());
    try stream.establish(glowcap.net.clock.nowMs(io) + 1_000, null);

    // WakeChannel descriptors are nonblocking. A one-read implementation
    // returns this prefix immediately; readSliceShort would issue another raw
    // read in an attempt to fill the TLS record window and turn ordinary
    // partial arrival into a refusal (or park forever on a blocking socket).
    try writeAllNonblocking(io, pair.write, "now");
    var observed: [3]u8 = undefined;
    try stream.reader.interface.readSliceAll(&observed);
    try std.testing.expectEqualStrings("now", &observed);
    try std.testing.expectEqual(@as(?tls.Failure, null), stream.deinitOutcome());
}

test "pollable TLS reclaims consumed prefix before a fragmented record grows" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pair = try glowcap.net.wake_channel.WakeChannel.open();
    const raw: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.read,
        .address = undefined,
    } };
    const peer: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.write,
        .address = undefined,
    } };
    defer peer.close(io);
    try setSocketBuffer(pair.read, std.c.SO.RCVBUF, 4 * record_bytes);
    try setSocketBuffer(pair.write, std.c.SO.SNDBUF, 4 * record_bytes);
    var fake = FragmentedRecordEngine{};
    const stream = try PollableStream.create(allocator, io, raw, fake.client());
    try stream.establish(glowcap.net.clock.nowMs(io) + 1_000, null);

    const ciphertext = @as([record_bytes + 1]u8, @splat('x'));
    try writeAllNonblocking(io, pair.write, &ciphertext);
    try std.testing.expectEqual(
        glowcap.net.tls.pollable_stream.TryProgress.progress,
        try stream.tryFill(),
    );
    try std.testing.expectEqual(@as(u8, 'x'), try stream.reader.interface.takeByte());
    try std.testing.expectEqual(@as(?tls.Failure, null), stream.deinitOutcome());
}

test "pollable TLS fails a handshake whose full ciphertext window the engine cannot parse" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // A window one byte short still has room for the engine's next read and
    // only times out. A full window has none and fails with the exact cause.
    for ([_]usize{ record_bytes - 1, record_bytes }) |sent| {
        const pair = try glowcap.net.wake_channel.WakeChannel.open();
        const raw: std.Io.net.Stream = .{ .socket = .{
            .handle = pair.read,
            .address = undefined,
        } };
        const peer: std.Io.net.Stream = .{ .socket = .{
            .handle = pair.write,
            .address = undefined,
        } };
        defer peer.close(io);
        try setSocketBuffer(pair.read, std.c.SO.RCVBUF, 4 * record_bytes);
        try setSocketBuffer(pair.write, std.c.SO.SNDBUF, 4 * record_bytes);
        const ciphertext = @as([record_bytes]u8, @splat('x'));
        try writeAllNonblocking(io, pair.write, ciphertext[0..sent]);

        // The engine waits for more and never consumes a byte.
        var fake = WaitingHandshakeEngine{};
        const stream = try PollableStream.create(allocator, io, raw, fake.client());
        const wait_ms: i64 = if (sent == record_bytes) 1_000 else 50;
        const established = stream.establish(glowcap.net.clock.nowMs(io) + wait_ms, null);
        const failure = stream.takeFailure();
        try std.testing.expectEqual(@as(?tls.Failure, null), stream.deinitOutcome());
        try std.testing.expectEqual(@as(usize, 1), fake.deinit_count);

        if (sent == record_bytes) {
            try std.testing.expectError(error.TlsFailed, established);
            const exact = failure orelse return error.MissingTlsFailure;
            try std.testing.expectEqual(tls.Phase.handshake, exact.phase);
            try std.testing.expectEqualStrings("TlsCiphertextLimit", exact.chain.primaryName());
        } else {
            try std.testing.expectError(error.TimedOut, established);
            try std.testing.expectEqual(@as(?tls.Failure, null), failure);
        }
    }
}
