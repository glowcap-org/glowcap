//! Deterministic socket-driver evidence for the generic TLS transform.

const std = @import("std");
const pancake = @import("pancake");

const tls = pancake.net.tls.engine;
const PollableStream = pancake.net.tls.pollable_stream.Stream;
const record_bytes = 18 * 1024;

test "pollable TLS connection state has a measured footprint" {
    try std.testing.expectEqual(
        @as(usize, 45_616),
        pancake.net.tls.pollable_stream.connection_state_bytes,
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

    fn deinit(raw: *anyopaque) ?pancake.foundation.FailureChain {
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

    fn deinit(_: *anyopaque) ?pancake.foundation.FailureChain {
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

    fn deinit(raw: *anyopaque) ?pancake.foundation.FailureChain {
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
    const pair = try pancake.net.wake_channel.WakeChannel.open();
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
        pair.stream.establish(pancake.net.clock.nowMs(std.testing.io) + 1_000, &stop),
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
        pair.stream.establish(pancake.net.clock.nowMs(std.testing.io), null),
    );
    try std.testing.expectEqual(@as(?tls.Failure, null), pair.stream.takeFailure());
    try std.testing.expectEqual(@as(?tls.Failure, null), pair.stream.deinitOutcome());
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_count);
}

test "pollable TLS owns bidirectional bytes and reports truncation once" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pair = try pancake.net.wake_channel.WakeChannel.open();
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
    var peer_write_store: [32]u8 = undefined;
    var peer_reader = peer.reader(io, &peer_read_store);
    var peer_writer = peer.writer(io, &peer_write_store);

    var fake = IdentityEngine{};
    const stream = try PollableStream.create(allocator, io, raw, fake.client());
    try stream.establish(pancake.net.clock.nowMs(io) + 1_000, null);

    try stream.writer.interface.writeAll("outbound");
    try stream.writer.interface.flush();
    var observed: [8]u8 = undefined;
    try peer_reader.interface.readSliceAll(&observed);
    try std.testing.expectEqualStrings("outbound", &observed);

    try peer_writer.interface.writeAll("inbound");
    try peer_writer.interface.flush();
    try std.testing.expectEqual(
        pancake.net.tls.pollable_stream.TryProgress.progress,
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
    const pair = try pancake.net.wake_channel.WakeChannel.open();
    const raw: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.read,
        .address = undefined,
    } };
    const peer: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.write,
        .address = undefined,
    } };
    defer peer.close(io);
    var peer_write_store: [32]u8 = undefined;
    var peer_writer = peer.writer(io, &peer_write_store);

    var fake = IdentityEngine{};
    const stream = try PollableStream.create(allocator, io, raw, fake.client());
    try stream.establish(pancake.net.clock.nowMs(io) + 1_000, null);

    // WakeChannel descriptors are nonblocking. A one-read implementation
    // returns this prefix immediately; readSliceShort would issue another raw
    // read in an attempt to fill the TLS record window and turn ordinary
    // partial arrival into a refusal (or park forever on a blocking socket).
    try peer_writer.interface.writeAll("now");
    try peer_writer.interface.flush();
    var observed: [3]u8 = undefined;
    try stream.reader.interface.readSliceAll(&observed);
    try std.testing.expectEqualStrings("now", &observed);
    try std.testing.expectEqual(@as(?tls.Failure, null), stream.deinitOutcome());
}

test "pollable TLS reclaims consumed prefix before a fragmented record grows" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pair = try pancake.net.wake_channel.WakeChannel.open();
    const raw: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.read,
        .address = undefined,
    } };
    const peer: std.Io.net.Stream = .{ .socket = .{
        .handle = pair.write,
        .address = undefined,
    } };
    defer peer.close(io);
    var peer_write_store: [record_bytes + 1]u8 = undefined;
    var peer_writer = peer.writer(io, &peer_write_store);

    var fake = FragmentedRecordEngine{};
    const stream = try PollableStream.create(allocator, io, raw, fake.client());
    try stream.establish(pancake.net.clock.nowMs(io) + 1_000, null);

    const ciphertext = [_]u8{'x'} ** (record_bytes + 1);
    try peer_writer.interface.writeAll(&ciphertext);
    try peer_writer.interface.flush();
    try std.testing.expectEqual(
        pancake.net.tls.pollable_stream.TryProgress.progress,
        try stream.tryFill(),
    );
    try std.testing.expectEqual(@as(u8, 'x'), try stream.reader.interface.takeByte());
    try std.testing.expectEqual(@as(?tls.Failure, null), stream.deinitOutcome());
}
