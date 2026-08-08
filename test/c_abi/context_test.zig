//! Allocation-context contract independent of any CapTP application handle.
//! A caller-supplied allocator owns the context, TCP netlayer, listener,
//! connections, their buffers, and an owned frame; teardown returns every byte
//! through the same callbacks.

const std = @import("std");

const c = @import("c_abi");
const ct = @import("c_abi_net_transport_tcp");

const frame = "<8'op:abort3\"bye>";
const frame_cap = 4096;

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

test "context constructors reject null arguments" {
    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new(null));
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new_with_allocator(null, &ctx));

    var host = CountingHost{};
    var partial = host.spec();
    partial.free = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new_with_allocator(&partial, &ctx));

    c.pancake_context_release(null);
    try std.testing.expect(host.balanced());
}

const AcceptArgs = struct {
    listener: *ct.PancakeTcpListener,
    result: anyerror!void = {},
};

fn acceptThread(args: *AcceptArgs) void {
    args.result = acceptOnce(args);
}

fn acceptOnce(args: *AcceptArgs) !void {
    var conn: ?*ct.PancakeTcpConn = null;
    if (ct.pancake_tcp_accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn) != c.PANCAKE_OK)
        return error.AcceptFailed;
    const conn_ptr = conn orelse return error.AcceptNull;
    defer ct.pancake_tcp_conn_release(conn_ptr);

    var managed: c.PancakeManagedFrame = undefined;
    if (ct.pancake_tcp_conn_read_frame(conn_ptr, &managed) != c.PANCAKE_OK) return error.ReadFailed;
    defer c.pancake_managed_frame_release(&managed);

    const bytes = (managed.bytes orelse return error.NullFrame)[0..managed.len];
    try std.testing.expectEqualStrings(frame, bytes);
}

test "host allocator balances a TCP handle family and owned frame" {
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

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args: AcceptArgs = .{ .listener = listener_ptr };
    var accept_future = try io.concurrent(acceptThread, .{&args});

    var conn: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn),
    );
    const conn_ptr = conn.?;

    var outbound: c.PancakeFrame = .{
        .bytes = frame.ptr,
        .len = frame.len,
        .shape = c.PANCAKE_FRAME_SHAPE_BYTE,
    };
    const write_rc = ct.pancake_tcp_conn_write_frame(conn_ptr, &outbound);

    accept_future.await(io);
    ct.pancake_tcp_conn_release(conn_ptr);
    ct.pancake_tcp_listener_release(listener_ptr);
    ct.pancake_tcp_netlayer_release(netlayer_ptr);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expectEqual(c.PANCAKE_OK, write_rc);
    try args.result;
    try std.testing.expect(host.alloc_calls > 0);
    try std.testing.expect(host.balanced());
}

test "tcp connect and accept reject the unknown codec selector" {
    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&ctx));
    const ctx_ptr = ctx.?;
    defer c.pancake_context_release(ctx_ptr);

    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new_in(ctx_ptr, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.PancakeTcpListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;
    defer ct.pancake_tcp_listener_release(listener_ptr);

    var conn: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, 1, c.PANCAKE_CODEC_UNKNOWN, frame_cap, &conn),
    );
    try std.testing.expect(conn == null);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_accept(listener_ptr, c.PANCAKE_CODEC_UNKNOWN, frame_cap, &conn),
    );
    try std.testing.expect(conn == null);
}
