const std = @import("std");

const c = @import("c_abi_shared");
const tcp = @import("c_abi_net_transport_tcp");

const enabled_stream: tcp.GlowcapTcpStreamOptions = .{
    .keepalive_idle_sec = 30,
    .keepalive_interval_sec = 10,
    .keepalive_count = 3,
};
const disabled_operation: tcp.GlowcapTcpOperationOptions = .{ .stream = .{
    .keepalive_idle_sec = 0,
    .keepalive_interval_sec = 0,
    .keepalive_count = 0,
} };

const LocatorCapture = struct {
    designator: [128]u8 = undefined,
    len: usize = 0,

    fn sink(raw: ?*anyopaque, view: ?*const c.GlowcapLocatorView) callconv(.c) i32 {
        const self: *LocatorCapture = @ptrCast(@alignCast(raw orelse return c.GLOWCAP_ERR_NULL_POINTER));
        const locator = view orelse return c.GLOWCAP_ERR_NULL_POINTER;
        if (locator.designator_len > self.designator.len) return c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
        const source = (locator.designator orelse return c.GLOWCAP_ERR_NULL_POINTER)[0..locator.designator_len];
        @memcpy(self.designator[0..source.len], source);
        self.len = source.len;
        return c.GLOWCAP_OK;
    }

    fn slice(self: *const LocatorCapture) []const u8 {
        return self.designator[0..self.len];
    }
};

fn keepaliveEnabled(fd: i32) !bool {
    const sys = std.posix.system;
    var value: c_int = 0;
    var len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = sys.getsockopt(fd, sys.SOL.SOCKET, sys.SO.KEEPALIVE, @ptrCast(&value), &len);
    if (rc != 0) return error.GetSockOptFailed;
    return value != 0;
}

fn plainTable(provider: c.GlowcapTransportProvider) *const c.GlowcapStreamTransport {
    const entry = provider.entries.?[0];
    return @ptrCast(@alignCast(entry.implementation.?));
}

test "TCP provider operation options inherit, override, validate, and survive listener setup" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const config: tcp.GlowcapTcpConfig = .{ .stream = enabled_stream };
    var netlayer: ?*tcp.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_netlayer_new(&config, &netlayer));
    defer tcp.glowcap_tcp_netlayer_release(netlayer);

    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_transport_provider(netlayer, &provider));
    const table = plainTable(provider);

    const disabled_envelope: c.GlowcapTransportOperationOptions = .{
        .data = &disabled_operation,
        .size = @sizeOf(tcp.GlowcapTcpOperationOptions),
    };
    var listen_result: c.GlowcapListenResult = undefined;
    const requested = "127.0.0.1:0";
    try std.testing.expectEqual(c.GLOWCAP_OK, table.listen.?(
        table.ctx,
        requested.ptr,
        requested.len,
        null,
        0,
        &disabled_envelope,
        &listen_result,
        null,
    ));
    try std.testing.expectEqual(c.GLOWCAP_LISTEN_READY, listen_result.state);
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.listener_close.?(table.ctx, listen_result.listener, null),
    ) catch unreachable;

    var captured = LocatorCapture{};
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.listener_locator.?(listen_result.listener, &captured, LocatorCapture.sink, null),
    );
    const locator: c.GlowcapLocatorView = .{
        .abi_version = c.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapLocatorView),
        .transport = "tcp".ptr,
        .transport_len = "tcp".len,
        .designator = captured.slice().ptr,
        .designator_len = captured.slice().len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = c.locator.GLOWCAP_HINTS_MAP,
    };

    var attempt: ?*anyopaque = null;
    var completion_fd: i32 = -1;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.start_connect.?(table.ctx, &locator, null, &attempt, &completion_fd, null),
    );
    var completion_poll = [_]std.posix.pollfd{.{
        .fd = completion_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&completion_poll, 1_000));

    var client: ?*anyopaque = null;
    var client_fd: i32 = -1;
    try std.testing.expectEqual(c.GLOWCAP_OK, table.finish_connect.?(attempt, &client, &client_fd, null));
    defer std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, client, null)) catch unreachable;
    try std.testing.expect(try keepaliveEnabled(client_fd));

    try std.testing.expectEqual(c.GLOWCAP_OK, table.listener_wait_acceptable.?(
        table.ctx,
        listen_result.listener,
        1_000,
        null,
    ));
    var server: ?*anyopaque = null;
    var server_fd: i32 = -1;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.accept.?(table.ctx, listen_result.listener, &server, &server_fd, null),
    );
    defer std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, server, null)) catch unreachable;
    try std.testing.expect(!(try keepaliveEnabled(server_fd)));

    var untouched: ?*anyopaque = @ptrFromInt(@alignOf(usize));
    var untouched_fd: i32 = 77;
    const wrong_size: c.GlowcapTransportOperationOptions = .{
        .data = &disabled_operation,
        .size = @sizeOf(tcp.GlowcapTcpOperationOptions) - 1,
    };
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &locator, &wrong_size, &untouched, &untouched_fd, null),
    );
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(@alignOf(usize))), untouched);
    try std.testing.expectEqual(@as(i32, 77), untouched_fd);

    var misaligned_storage: [@sizeOf(tcp.GlowcapTcpOperationOptions) + @alignOf(tcp.GlowcapTcpOperationOptions)]u8 align(@alignOf(tcp.GlowcapTcpOperationOptions)) = undefined;
    const misaligned: c.GlowcapTransportOperationOptions = .{
        .data = &misaligned_storage[1],
        .size = @sizeOf(tcp.GlowcapTcpOperationOptions),
    };
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &locator, &misaligned, &untouched, &untouched_fd, null),
    );
}

test "TCP provider listen reports its exact operation-local failure" {
    const config: tcp.GlowcapTcpConfig = .{ .stream = enabled_stream };
    var netlayer: ?*tcp.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_netlayer_new(&config, &netlayer));
    defer tcp.glowcap_tcp_netlayer_release(netlayer);

    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, tcp.glowcap_tcp_transport_provider(netlayer, &provider));
    const table = plainTable(provider);
    var result: c.GlowcapListenResult = undefined;
    var failure = c.transport_provider.emptyProviderFailure();
    const invalid = "not-a-socket-address";
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, table.listen.?(
        table.ctx,
        invalid.ptr,
        invalid.len,
        null,
        0,
        null,
        &result,
        &failure,
    ));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, failure.result);
    try std.testing.expectEqualStrings("InvalidAddress", failure.primary_name.?[0..failure.primary_name_len]);
    try std.testing.expectEqual(@as(u32, 0), failure.secondary_count);
}
