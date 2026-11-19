//! Check the event-driven stream table after its queued socket was claimed.
const std = @import("std");
const c = @import("c_abi_shared");

pub fn expectDrained(table: *const c.GlowcapStreamTransport, listener: ?*anyopaque, stream_fd: i32) !void {
    const sys = std.c;
    const listener_fd = table.listener_readiness_fd.?(table.ctx, listener);
    const listener_flags = sys.fcntl(listener_fd, sys.F.GETFL, @as(c_int, 0));
    const stream_flags = sys.fcntl(stream_fd, sys.F.GETFL, @as(c_int, 0));
    const fd_flags = sys.fcntl(stream_fd, sys.F.GETFD, @as(c_int, 0));
    try std.testing.expect(listener_flags >= 0 and stream_flags >= 0 and fd_flags >= 0);
    const nonblocking: c_int = @bitCast(sys.O{ .NONBLOCK = true });
    try std.testing.expect(listener_flags & nonblocking != 0);
    try std.testing.expect(stream_flags & nonblocking == 0);
    try std.testing.expect(fd_flags & sys.FD_CLOEXEC != 0);

    try expectPending(table, listener);
}

pub fn expectPending(table: *const c.GlowcapStreamTransport, listener: ?*anyopaque) !void {
    const sentinel: ?*anyopaque = @ptrFromInt(@alignOf(usize));
    var conn = sentinel;
    var fd: i32 = 77;
    var report = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, table.accept.?(table.ctx, listener, &conn, &fd, &report));
    try std.testing.expectEqual(sentinel, conn);
    try std.testing.expectEqual(@as(i32, 77), fd);
    try std.testing.expect(c.transport_provider.providerFailureEmpty(report));
}
