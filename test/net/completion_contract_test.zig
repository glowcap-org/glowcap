//! Completion result and shared-buffer ownership contract evidence.

const std = @import("std");
const glowcap = @import("glowcap");

const completion = glowcap.net.completion;
const foundation = glowcap.foundation;

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

    var carrier = glowcap.net.carrier_failure.Failure.init(
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
        glowcap.net.carrier_failure.Phase.secure_handshake,
        carrier_failed.borrowed.carrierFailureValue().?.phase,
    );
    try std.testing.expectEqual(
        glowcap.net.carrier_failure.Phase.secure_handshake,
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
        glowcap.net.carrier_failure.Phase.connect,
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

/// An adapter that owns every odd `user_data` and projects each owned record
/// as one record of its own, refusing the one that names it.
const OddOwner = struct {
    ready: completion.ReadyQueue = .{},
    refused: u64,

    pub fn ownsCompletion(user_data: u64) bool {
        return user_data % 2 == 1;
    }

    pub fn dispatchOwned(self: *OddOwner, record: completion.Completion) !void {
        if (record.user_data == self.refused) return error.DispatchRefused;
        try self.ready.append(std.testing.allocator, .{ .user_data = record.user_data * 100, .result = 0 });
    }
};

test "an adapter keeps foreign records in place and its own never reach the caller" {
    var owner: OddOwner = .{ .refused = 99 };
    defer owner.ready.deinit(std.testing.allocator);
    var out: [8]completion.Completion = undefined;
    inline for (.{ 2, 3, 4, 5, 6 }, 0..) |user_data, i| out[i] = .{ .user_data = user_data, .result = 0 };

    const kept = try completion.keepForeign(&out, 5, OddOwner, &owner);
    try std.testing.expectEqual(@as(usize, 3), kept);
    try std.testing.expectEqual(@as(u64, 2), out[0].user_data);
    try std.testing.expectEqual(@as(u64, 4), out[1].user_data);
    try std.testing.expectEqual(@as(u64, 6), out[2].user_data);

    // The projections drain into the room after the kept records, in the
    // order they were owed.
    const total = kept + owner.ready.drain(out[kept..]);
    try std.testing.expectEqual(@as(usize, 5), total);
    try std.testing.expectEqual(@as(u64, 300), out[3].user_data);
    try std.testing.expectEqual(@as(u64, 500), out[4].user_data);
    for (out[0..total]) |record| try std.testing.expect(!OddOwner.ownsCompletion(record.user_data));

    // A refused dispatch refuses the pass.
    out[0] = .{ .user_data = 99, .result = 0 };
    try std.testing.expectError(error.DispatchRefused, completion.keepForeign(&out, 1, OddOwner, &owner));
}

test "an adapter with nothing open still delivers what it owes before a pass goes through" {
    // The idle pass hands the caller's room to the platform untouched. A
    // record already owed on the adapter's ready queue is one of the things
    // that keeps the pass from going through, so it leaves first.
    const admission = @import("../support/keyed_relay_admission.zig");
    var backend = try admission.admissionBackend(std.testing.allocator);
    defer admission.deinitAdmissionBackend(&backend);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());

    var out: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.peek(&out));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.poll_calls);

    try backend.ready.append(std.testing.allocator, .{ .user_data = 24, .result = 0 });
    try std.testing.expectEqual(@as(usize, 1), try backend.peek(&out));
    try std.testing.expectEqual(@as(u64, 24), out[0].user_data);
    try std.testing.expectEqual(@as(usize, 2), backend.platform.poll_calls);
    try std.testing.expectEqual(@as(usize, 0), try backend.peek(&out));
}
