//! The hinted try-I/O machine on a connection that has seen no readiness
//! edge. A sidecar reports each edge once, so bytes that arrived before the
//! connection had its row are reachable only by attempting the read.

const std = @import("std");
const glowcap = @import("glowcap");

const completion = glowcap.net.completion;

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

    pub fn closeOnFailure(_: *Entry) void {}

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
