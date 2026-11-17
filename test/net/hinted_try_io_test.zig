//! The hinted try-I/O machine on a connection that has seen no readiness
//! edge. A sidecar reports each edge once, so bytes that arrived before the
//! connection had its row are reachable only by attempting the read.

const std = @import("std");
const glowcap = @import("glowcap");

const completion = glowcap.net.completion;
const FailingOnce = @import("../support/failing_once.zig").FailingOnce;

const Backend = struct {
    pub const Fd = i32;

    conns: std.AutoHashMapUnmanaged(Fd, Ops.Entry) = .empty,
    buffer_pool: completion.BufferPool,
    published: [2]completion.Completion = undefined,
    published_count: usize = 0,
};

const Ops = struct {
    pub const Entry = struct {
        pending: completion.HintedPending = .{},
        /// Bytes the far peer sent before this row existed.
        inbound: []const u8 = "",
        read_calls: usize = 0,
        close_calls: usize = 0,
    };

    pub const holds_admission_seat = false;

    pub fn tryRead(entry: *Entry, buf: []u8) completion.TryRead {
        entry.read_calls += 1;
        if (entry.inbound.len == 0) return .would_block;
        const n = @min(buf.len, entry.inbound.len);
        @memcpy(buf[0..n], entry.inbound[0..n]);
        entry.inbound = entry.inbound[n..];
        return .{ .transferred = n };
    }

    pub fn tryWrite(_: *Entry, bytes: []const u8) completion.TryWrite {
        return .{ .transferred = bytes.len };
    }

    pub fn closeOnFailure(entry: *Entry) void {
        entry.close_calls += 1;
    }

    pub fn borrowToken(index: u32) u32 {
        return index;
    }

    pub fn reserveSeats(backend: *Backend, count: usize) !void {
        if (backend.published_count + count > backend.published.len) return error.OutOfMemory;
    }

    pub fn publish(backend: *Backend, comp: completion.Completion) void {
        backend.published[backend.published_count] = comp;
        backend.published_count += 1;
    }
};

const TryIo = completion.HintedTryIo(Backend, Ops);

test "a fresh connection reads bytes that arrived before it had a row" {
    var backend: Backend = .{ .buffer_pool = try completion.BufferPool.init(std.testing.allocator, 1, 64) };
    defer backend.buffer_pool.deinit();
    defer backend.conns.deinit(std.testing.allocator);
    try backend.conns.put(std.testing.allocator, 3, .{ .inbound = "hello" });

    try TryIo.submitRecv(&backend, 7, 3);
    try std.testing.expectEqual(@as(usize, 1), backend.published_count);
    try std.testing.expectEqual(@as(u64, 7), backend.published[0].user_data);
    try std.testing.expectEqual(@as(i32, 5), backend.published[0].result);
    backend.buffer_pool.release(@intCast(backend.published[0].borrowed.token));
}

test "a fresh connection with nothing to read parks after one attempt" {
    var backend: Backend = .{ .buffer_pool = try completion.BufferPool.init(std.testing.allocator, 1, 64) };
    defer backend.buffer_pool.deinit();
    defer backend.conns.deinit(std.testing.allocator);
    try backend.conns.put(std.testing.allocator, 3, .{});

    try TryIo.submitRecv(&backend, 7, 3);
    const entry = backend.conns.getPtr(3).?;
    try std.testing.expectEqual(@as(usize, 1), entry.read_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.published_count);
    try std.testing.expectEqual(@as(?u64, 7), entry.pending.read_ud);
}

test "refused buffer growth latches the connection cause and exhaustion waits for a recycle" {
    var failing = FailingOnce.init(std.testing.allocator, std.math.maxInt(usize));
    var backend: Backend = .{ .buffer_pool = try completion.BufferPool.init(failing.allocator(), 1, 64) };
    defer backend.buffer_pool.deinit();
    defer backend.conns.deinit(std.testing.allocator);
    try backend.conns.put(std.testing.allocator, 3, .{ .inbound = "hello" });
    try backend.conns.put(std.testing.allocator, 4, .{ .inbound = "world" });

    // Real refusal at this backend's own pool: nothing grows or leases, and
    // the connection latches the exact cause once.
    failing.fail_index = failing.alloc_index;
    try TryIo.submitRecv(&backend, 7, 3);
    try std.testing.expect(failing.induced);
    try std.testing.expectEqual(@as(usize, 0), backend.buffer_pool.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), backend.buffer_pool.leasedCount());
    try std.testing.expectEqual(@as(usize, 1), backend.published_count);
    const refused = backend.published[0];
    try std.testing.expectEqual(@as(u64, 7), refused.user_data);
    try std.testing.expect(refused.result < 0);
    try std.testing.expectEqual(error.OutOfMemory, refused.failure.?);
    try std.testing.expect(!refused.recv_no_buffer);
    try std.testing.expect(!refused.borrowed.active());
    const entry = backend.conns.getPtr(3).?;
    try std.testing.expectEqual(@as(?u64, null), entry.pending.read_ud);
    try std.testing.expectEqual(error.OutOfMemory, entry.pending.terminal_failure.?);
    try std.testing.expectEqual(@as(usize, 1), entry.close_calls);
    try std.testing.expectEqual(@as(usize, 0), entry.read_calls);

    // A later operation on the same connection settles with the same cause
    // without touching the sidecar or the pool, even with memory back.
    failing.fail_index = std.math.maxInt(usize);
    backend.published_count = 0;
    try TryIo.submitRecv(&backend, 8, 3);
    try std.testing.expectEqual(@as(usize, 1), backend.published_count);
    try std.testing.expectEqual(error.OutOfMemory, backend.published[0].failure.?);
    try std.testing.expectEqual(@as(usize, 0), entry.read_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.buffer_pool.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), entry.close_calls);

    // The latch is per connection: another one still reads, and genuine
    // exhaustion keeps reporting starvation until the lease recycles.
    backend.published_count = 0;
    try TryIo.submitRecv(&backend, 9, 4);
    const lent = backend.published[0];
    try std.testing.expect(lent.borrowed.kind == .recv);
    try backend.conns.put(std.testing.allocator, 5, .{ .inbound = "again" });
    backend.published_count = 0;
    try TryIo.submitRecv(&backend, 10, 5);
    try std.testing.expect(backend.published[0].recv_no_buffer);
    try std.testing.expectEqual(@as(?anyerror, null), backend.published[0].failure);
    try std.testing.expectEqual(@as(?anyerror, null), backend.conns.getPtr(5).?.pending.terminal_failure);
    backend.buffer_pool.release(@intCast(lent.borrowed.token));
}
