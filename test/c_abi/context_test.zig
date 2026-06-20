//! C ABI allocation-context contract, proves a `PancakeContext` owns allocation
//! policy for a whole handle family. Every allocation a context-scoped handle
//! makes (the peer and netlayer objects, the managed outbound/event frames,
//! adopted inbound frames, TCP connection/listener payloads and their buffers,
//! and the context object itself) routes through the context's allocator, and
//! every one is freed back through it. A host-supplied allocator built from the
//! C callbacks lets these tests count allocations and assert the balance is
//! exactly zero after teardown.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const ct = @import("c_abi_net_transport_tcp");
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;

const abort_frame = "<8'op:abort3\"bye>";
const frame_cap = 4096;

/// A host allocator (the `pancake_context_new_with_allocator` callbacks) backed
/// by the testing allocator, counting every allocation and free. Thread-safe so
/// the TCP loopback's worker threads can allocate concurrently.
const CountingHost = struct {
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    live_bytes: usize = 0,

    fn spec(self: *CountingHost) c.PancakeAllocator {
        return .{ .alloc = hostAlloc, .free = hostFree, .user_data = self };
    }

    fn balanced(self: *const CountingHost) bool {
        return self.alloc_calls == self.free_calls and self.live_bytes == 0;
    }

    fn hostAlloc(user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *CountingHost = @ptrCast(@alignCast(user_data.?));
        const al = std.mem.Alignment.fromByteUnits(alignment);
        const ptr = std.testing.allocator.rawAlloc(size, al, @returnAddress()) orelse return null;
        _ = @atomicRmw(usize, &self.alloc_calls, .Add, 1, .monotonic);
        _ = @atomicRmw(usize, &self.live_bytes, .Add, size, .monotonic);
        return @ptrCast(ptr);
    }

    fn hostFree(user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self: *CountingHost = @ptrCast(@alignCast(user_data.?));
        const al = std.mem.Alignment.fromByteUnits(alignment);
        const slice = @as([*]u8, @ptrCast(ptr.?))[0..size];
        std.testing.allocator.rawFree(slice, al, @returnAddress());
        _ = @atomicRmw(usize, &self.free_calls, .Add, 1, .monotonic);
        _ = @atomicRmw(usize, &self.live_bytes, .Sub, size, .monotonic);
    }
};

/// Build an external managed frame over caller-owned bytes whose `release`
/// flips a flag, the same shape a `pancake_tcp_conn_read_frame` hands out,
/// minus a backing allocation, so a test can feed it owned and watch it release.
const ExternalFrame = struct {
    var released: bool = false;

    fn release(frame: *c.PancakeManagedFrame) callconv(.c) void {
        released = true;
        frame.bytes = null;
        frame.len = 0;
        frame.release = null;
        frame.private_data = null;
    }

    fn make(bytes: []u8) c.PancakeManagedFrame {
        released = false;
        return .{
            .bytes = bytes.ptr,
            .len = bytes.len,
            .shape = c.PANCAKE_FRAME_SHAPE_BYTE,
            .release = release,
            .private_data = null,
        };
    }
};

test "default context creates and releases a peer" {
    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&ctx));
    const ctx_ptr = ctx.?;
    defer c.pancake_context_release(ctx_ptr);

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_in(ctx_ptr, &peer));
    c.pancake_peer_release(peer);
}

test "context constructors reject null arguments" {
    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new(null));
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new_with_allocator(null, &ctx));

    // alloc/free are required; a spec missing either is a null-pointer error.
    var host = CountingHost{};
    var partial = host.spec();
    partial.free = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new_with_allocator(&partial, &ctx));

    // Releasing a null context is a no-op (no allocation happened to balance).
    c.pancake_context_release(null);
    try std.testing.expect(host.balanced());
}

test "host context balances a peer, an adopted inbound frame, and its event frame" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_in(ctx_ptr, &peer));

    var bytes = (abort_frame.*);
    var managed = ExternalFrame.make(bytes[0..]);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_owned(peer, &managed));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));

    var event: c.PancakeEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event(peer, &event));
    try std.testing.expectEqual(c.PANCAKE_EVENT_ABORT, event.kind);

    // The host allocator actually carried the load (the context object, the peer,
    // the adopted wrapper, the event-frame wrapper), not the library default.
    try std.testing.expect(host.alloc_calls > 0);

    c.pancake_event_release(&event);
    try std.testing.expect(ExternalFrame.released);

    c.pancake_peer_release(peer);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expect(host.balanced());
}

test "host context balances an outbound managed frame" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_in(ctx_ptr, &peer));

    // Drive an outbound frame through the public Zig boundary the C handle wraps.
    const runtime_peer: *engine.Peer = @ptrCast(@alignCast(peer.?));
    try runtime_peer.sendCopying(.{ .abort = .{ .kind = .normal_shutdown, .message = "bye" } });
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));

    var outbound: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &outbound));
    try std.testing.expect(outbound.release != null);
    c.pancake_managed_frame_release(&outbound);

    c.pancake_peer_release(peer);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expect(host.balanced());
}

test "host context: feed_owned failure frees the adopted wrapper and consumes the frame" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_in(ctx_ptr, &peer));

    // A word-shaped frame whose length is not a multiple of 8 is rejected by the
    // frame layer; the adopted wrapper allocated up front must be freed, and the
    // frame is consumed, released once through its own callback, with the
    // caller's struct cleared so a late release is a no-op.
    var bytes = [_]u8{ 1, 2, 3 };
    var managed = ExternalFrame.make(bytes[0..]);
    managed.shape = c.PANCAKE_FRAME_SHAPE_WORD;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_peer_feed_owned(peer, &managed));
    try std.testing.expect(ExternalFrame.released);
    try std.testing.expect(managed.bytes == null);

    c.pancake_managed_frame_release(&managed);

    c.pancake_peer_release(peer);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expect(host.balanced());
}

/// A bump-arena host allocator over a fixed buffer — no libc, no testing
/// allocator — proving allocation policy is genuinely the host's. It counts
/// calls so a test can pin the exact number of allocations a handle makes.
const TrackingAllocator = struct {
    storage: [16 * 1024]u8 align(16) = undefined,
    used: usize = 0,
    alloc_count: usize = 0,
    free_count: usize = 0,

    fn spec(self: *TrackingAllocator) c.PancakeAllocator {
        return .{ .alloc = alloc, .free = free, .user_data = self };
    }

    fn alloc(user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *TrackingAllocator = @ptrCast(@alignCast(user_data orelse return null));
        const base = @intFromPtr(self.storage[0..].ptr);
        const aligned = std.mem.alignForward(usize, base + self.used, alignment);
        const new_used = (aligned - base) + size;
        if (new_used > self.storage.len) return null;
        self.used = new_used;
        self.alloc_count += 1;
        return @ptrFromInt(aligned);
    }

    fn free(user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        _ = .{ ptr, size, alignment };
        const self: *TrackingAllocator = @ptrCast(@alignCast(user_data orelse return));
        self.free_count += 1;
    }
};

test "host context pins the exact allocation count of a peer's lifecycle" {
    var tracker = TrackingAllocator{};
    const spec = tracker.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    // The context object itself is the first host allocation.
    try std.testing.expectEqual(@as(usize, 1), tracker.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), tracker.free_count);

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_in(ctx.?, &peer));
    // The peer object is the second; session tables allocate lazily on demand.
    try std.testing.expectEqual(@as(usize, 2), tracker.alloc_count);

    c.pancake_peer_release(peer);
    try std.testing.expectEqual(@as(usize, 1), tracker.free_count);

    c.pancake_context_release(ctx.?);
    try std.testing.expectEqual(tracker.alloc_count, tracker.free_count);
}

test "host context stays balanced while session tables grow and rehash" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_in(ctx_ptr, &peer));

    // Registering many distinct swissnums grows and rehashes the bootstrap
    // registry through the host allocator. With no in-place resize, each growth
    // is an alloc-copy-free; the testing allocator under the host callbacks would
    // trip if any `free` size disagreed with its `alloc` size.
    var buf: [8]u8 = undefined;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const swiss = std.fmt.bufPrint(&buf, "cap-{d:0>4}", .{i}) catch unreachable;
        var export_position: u64 = 0;
        try std.testing.expectEqual(
            c.PANCAKE_OK,
            c.pancake_peer_register_bootstrap_cap(peer, swiss.ptr, swiss.len, &export_position),
        );
    }

    c.pancake_peer_release(peer);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expect(host.balanced());
}

// ── TCP endpoint handles through a context ───────────────────────────────────

const TcpArgs = struct {
    listener: *ct.PancakeTcpListener,
    result: anyerror!void = {},
};

fn acceptThread(args: *TcpArgs) void {
    args.result = acceptOnce(args);
}

fn acceptOnce(args: *TcpArgs) !void {
    var conn: ?*ct.PancakeTcpConn = null;
    if (ct.pancake_tcp_accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn) != c.PANCAKE_OK)
        return error.AcceptFailed;
    const conn_ptr = conn orelse return error.AcceptNull;
    defer ct.pancake_tcp_conn_release(conn_ptr);

    var mf: c.PancakeManagedFrame = undefined;
    if (ct.pancake_tcp_conn_read_frame(conn_ptr, &mf) != c.PANCAKE_OK) return error.ReadFailed;
    defer c.pancake_managed_frame_release(&mf);

    const bytes = (mf.bytes orelse return error.NullFrame)[0..mf.len];
    try std.testing.expectEqualStrings(abort_frame, bytes);
}

test "host context balances a TCP netlayer, listener, connections, and a read frame" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new_in(ctx_ptr, &netlayer));
    const netlayer_ptr = netlayer.?;

    const host_addr = "127.0.0.1";
    var listener: ?*ct.PancakeTcpListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;

    var port: u16 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_listener_port(listener_ptr, &port));
    try std.testing.expect(port != 0);

    var args: TcpArgs = .{ .listener = listener_ptr };
    const thread = try std.Thread.spawn(.{}, acceptThread, .{&args});

    var conn: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn),
    );
    const conn_ptr = conn.?;

    var cf: c.PancakeFrame = .{ .bytes = abort_frame.ptr, .len = abort_frame.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    const write_rc = ct.pancake_tcp_conn_write_frame(conn_ptr, &cf);

    thread.join();
    ct.pancake_tcp_conn_release(conn_ptr);
    ct.pancake_tcp_listener_release(listener_ptr);
    ct.pancake_tcp_netlayer_release(netlayer_ptr);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expectEqual(c.PANCAKE_OK, write_rc);
    try args.result;
    try std.testing.expect(host.alloc_calls > 0);
    try std.testing.expect(host.balanced());
}
