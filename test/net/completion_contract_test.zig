//! Completion result and shared-buffer ownership contract evidence.

const std = @import("std");
const pancake = @import("pancake");

const completion = pancake.net.completion;
const foundation = pancake.foundation;

test "completion borrow distinguishes receive bytes from structured failure without growing" {
    const bytes = "bytes";
    const received = completion.Completion{
        .user_data = 1,
        .result = @intCast(bytes.len),
        .borrowed = .recv(bytes, 17),
    };
    try std.testing.expectEqualStrings(bytes, received.borrowed.recvBytes().?);
    try std.testing.expect(received.borrowed.failureChain() == null);
    try std.testing.expectEqual(@as(u32, 17), received.borrowed.token);

    const empty = completion.Completion{
        .user_data = 2,
        .result = 0,
        .borrowed = .recv("", 19),
    };
    try std.testing.expectEqual(@as(usize, 0), empty.borrowed.recvBytes().?.len);

    var chain = foundation.FailureChain.init(error.TlsHandshakeFailed);
    chain.note(error.SocketCloseFailed);
    chain.note(error.RuntimeReleaseFailed);
    const failed = completion.Completion{
        .user_data = 3,
        .result = -1,
        .failure = error.ConnectionRefused,
        .borrowed = .failure(&chain, 23),
    };
    try std.testing.expect(failed.borrowed.recvBytes() == null);
    try std.testing.expectEqual(error.TlsHandshakeFailed, failed.borrowed.failureChain().?.cause);
    try std.testing.expectEqual(error.SocketCloseFailed, failed.borrowed.failureChain().?.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 2), failed.borrowed.failureChain().?.secondary_count);
    try std.testing.expectEqual(@as(u32, 23), failed.borrowed.token);

    var carrier = pancake.net.carrier_failure.Failure.init(
        .secure_handshake,
        error.TlsHandshakeFailed,
    );
    carrier.chain.note(error.SocketCloseFailed);
    const carrier_failed = completion.Completion{
        .user_data = 4,
        .result = -1,
        .borrowed = .carrierFailure(&carrier, 29),
    };
    try std.testing.expectEqual(
        pancake.net.carrier_failure.Phase.secure_handshake,
        carrier_failed.borrowed.carrierFailureValue().?.phase,
    );
    try std.testing.expectEqual(
        pancake.net.carrier_failure.Phase.secure_handshake,
        carrier_failed.borrowed.carrierPhase().?,
    );
    try std.testing.expectEqual(
        error.TlsHandshakeFailed,
        carrier_failed.borrowed.failureChain().?.cause,
    );
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(completion.Completion));
}

test "completion scalar failure carries phase without retained storage" {
    const Borrowed = @FieldType(completion.Completion, "borrowed");
    const borrowed = Borrowed.phaseOnly(.connect);
    try std.testing.expect(!borrowed.active());
    try std.testing.expectEqual(
        pancake.net.carrier_failure.Phase.connect,
        borrowed.carrierPhase().?,
    );
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(completion.Completion));
}

test "completion buffer pool bounds leases and reuses released storage" {
    var pool = try completion.BufferPool.init(std.testing.allocator, 2, 32);
    defer pool.deinit();

    const first = pool.acquire().?;
    const second = pool.acquire().?;
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expectEqual(@as(usize, 2), pool.leasedCount());
    pool.release(first);
    try std.testing.expectEqual(first, pool.acquire().?);
    pool.release(first);
    pool.release(second);
    try std.testing.expectEqual(@as(usize, 0), pool.leasedCount());
}
