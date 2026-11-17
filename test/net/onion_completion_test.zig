const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const net = glowcap.net;
const completion = glowcap.net.completion;
const onion = glowcap.net.onion;

const sb = @import("../support/onion_script_backend.zig");

const service_id = sb.service_id;
const ScriptBackend = sb.ScriptBackend;
const Backend = sb.Backend;
const initBackend = sb.initBackend;
const pollOne = sb.pollOne;
const waitFor = sb.waitFor;
const openDial = sb.openDial;
const publishListener = sb.publishListener;
const closeDial = sb.closeDial;
const makePeer = sb.makePeer;
const target = sb.target;

test "Zig OnionLoop composes the onion adapter and completion Loop" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;

    comptime {
        std.debug.assert(net.OnionBackend == onion.completion.CompletionBackend(net.Backend));
        std.debug.assert(net.OnionDialResolver == onion.completion.DialResolver(net.tcp.DialResolver, net.Backend));
        std.debug.assert(net.OnionLoop == completion.Loop(net.OnionBackend, net.OnionDialResolver));
    }

    const allocator = std.testing.allocator;
    const platform = try net.Backend.init(allocator, 8, 1, 4096);
    const socks = try std.Io.net.IpAddress.parse("127.0.0.1", 9050);
    const backend = net.OnionBackend.initOnion(allocator, platform, .{ .socks = socks });

    var loop = try net.OnionLoop.initWithBackend(allocator, backend, makePeer, null, .{
        .max_conns = 1,
        .listen = null,
    });
    defer loop.deinit();

    try std.testing.expect(loop.listenerAddress() == null);
    try std.testing.expect(loop.port() == null);
}

test "onion completion footprint is pinned" {
    try std.testing.expectEqual(@as(usize, 240), Backend.connection_state_bytes);
}

test "onion completion Loop owns the listener address across backend move" {
    const control_reply = "250-ServiceID=" ++ service_id ++ "\r\n250 OK\r\n";
    const chunks = [_][]const u8{ "250 OK\r\n", control_reply };
    const backend = initBackend(std.testing.allocator, &chunks);
    const Resolver = struct {
        pub fn resolve(_: []const u8, _: []const u8, _: []const u8) !Backend.ConnectTarget {
            return error.UnsupportedTransport;
        }
    };
    const OnionLoop = completion.Loop(Backend, Resolver);
    var loop = try OnionLoop.initWithBackend(std.testing.allocator, backend, makePeer, null, .{
        .listen = 0,
        .max_conns = 1,
    });
    defer loop.deinit();

    const address = loop.listenerAddress().?.onion;
    try std.testing.expectEqualSlices(u8, service_id, &address);
    try std.testing.expect(loop.port() == null);
}

test "onion completion finishes fragmented SOCKS before lending coalesced application bytes" {
    const reply_tail = [_]u8{ 0x00, 0x01, 0, 0, 0, 0, 0, 0, 'a', 'p', 'p' };
    const chunks = [_][]const u8{
        &[_]u8{0x05},
        &[_]u8{0x00},
        &[_]u8{ 0x05, 0x00 },
        &reply_tail,
    };
    var backend = initBackend(std.testing.allocator, &chunks);
    backend.inner.max_send_bytes = 1;
    backend.inner.refuse_next_send = true;
    defer backend.deinit();

    const fd = try openDial(&backend, 100);
    try std.testing.expectEqualSlices(u8, &onion.socks5.greeting, backend.inner.sent_bytes.items[0..onion.socks5.greeting.len]);
    try std.testing.expectEqual(
        onion.socks5.greeting.len + onion.socks5.connect_request_len,
        backend.inner.sent_bytes.items.len,
    );

    const recycled_before = backend.inner.recycled_tokens.items.len;
    try backend.submitRecv(101, fd);
    const recv = try waitFor(&backend, 101);
    try std.testing.expectEqualStrings("app", recv.borrowed.recvBytes().?);
    try std.testing.expect(completion.AdapterNamespace(ScriptBackend).ownsBorrowToken(recv.borrowed.token));
    backend.recycleBorrowed(recv);
    try std.testing.expectEqual(recycled_before + 1, backend.inner.recycled_tokens.items.len);

    const payload = "caller-owned";
    const sends_before = backend.inner.sends.items.len;
    backend.inner.refuse_next_send = true;
    try std.testing.expectError(error.SubmitPressure, backend.submitSend(102, fd, payload));
    try std.testing.expectEqual(sends_before, backend.inner.sends.items.len);
    try std.testing.expect((try pollOne(&backend)) == null);
    try backend.submitSend(102, fd, payload);
    try std.testing.expectEqual(payload.ptr, backend.inner.sends.items[sends_before].ptr);
    _ = try waitFor(&backend, 102);
    try closeDial(&backend, fd, 103);
}

test "onion completion accepts every legal SOCKS bound-address tail" {
    const replies = [_][]const u8{
        &[_]u8{ 0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x23, 0x55 },
        &[_]u8{ 0x05, 0x00, 0x00, 0x03, 3, 'f', 'o', 'o', 0x23, 0x55 },
        &[_]u8{ 0x05, 0x00, 0x00, 0x04 } ++ @as([16]u8, @splat(0)) ++ [_]u8{ 0x23, 0x55 },
    };
    for (replies, 0..) |reply, i| {
        const chunks = [_][]const u8{ &[_]u8{ 0x05, 0x00 }, reply };
        var backend = initBackend(std.testing.allocator, &chunks);
        defer backend.deinit();
        const fd = try openDial(&backend, 200 + i);
        try closeDial(&backend, fd, 210 + i);
    }
}

test "onion completion fails a dial with the SOCKS refusal that ended it" {
    const refusals = [_]struct { chunks: []const []const u8, cause: anyerror }{
        // A greeting that selects another method, one that runs long, and Tor's "host unreachable" for an unfetched descriptor.
        .{ .chunks = &.{&[_]u8{ 0x05, 0xff }}, .cause = error.ProtocolViolation },
        .{ .chunks = &.{&[_]u8{ 0x05, 0x00, 0x05 }}, .cause = error.ProtocolViolation },
        .{ .chunks = &.{ &[_]u8{ 0x05, 0x00 }, &[_]u8{ 0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0 } }, .cause = error.ConnectRefused },
    };
    for (refusals, 0..) |refusal, i| {
        var backend = initBackend(std.testing.allocator, refusal.chunks);
        defer backend.deinit();
        const fd = try backend.startDial(220 + i, target());
        const connected = try waitFor(&backend, 220 + i);
        try std.testing.expectEqual(@as(i32, -1), connected.result);
        try std.testing.expectEqual(refusal.cause, connected.failure.?);
        try std.testing.expectEqual(.connect, connected.borrowed.carrierPhase().?);
        try closeDial(&backend, fd, 230 + i);
    }
}

test "onion completion ends a data receive with the exact refused-buffer cause" {
    const chunks = [_][]const u8{
        &[_]u8{ 0x05, 0x00 },
        &[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 },
    };
    var backend = initBackend(std.testing.allocator, &chunks);
    defer backend.deinit();
    const fd = try openDial(&backend, 400);
    backend.inner.refuse_recv_at = backend.inner.recv_index;

    try backend.submitRecv(401, fd);
    const received = try waitFor(&backend, 401);
    try std.testing.expect(received.result < 0);
    try std.testing.expectEqual(error.OutOfMemory, received.failure.?);
    try std.testing.expectEqual(.receive, received.borrowed.carrierPhase().?);
    try std.testing.expectEqual(@as(?usize, null), backend.inner.refuse_recv_at);
    try std.testing.expect((try pollOne(&backend)) == null);
    try closeDial(&backend, fd, 402);
}

test "onion completion fails the pending connect with a refused SOCKS handshake receive" {
    const cases = [_]struct { chunks: []const []const u8, refuse_at: usize }{
        // The greeting reply, then the connect reply.
        .{ .chunks = &.{}, .refuse_at = 0 },
        .{ .chunks = &.{&[_]u8{ 0x05, 0x00 }}, .refuse_at = 1 },
    };
    for (cases, 0..) |case, i| {
        var backend = initBackend(std.testing.allocator, case.chunks);
        defer backend.deinit();
        backend.inner.refuse_recv_at = case.refuse_at;
        const fd = try backend.startDial(420 + i, target());
        const connected = try waitFor(&backend, 420 + i);
        try std.testing.expectEqual(@as(i32, -1), connected.result);
        try std.testing.expectEqual(error.OutOfMemory, connected.failure.?);
        try std.testing.expectEqual(.connect, connected.borrowed.carrierPhase().?);
        try std.testing.expectEqual(@as(?usize, null), backend.inner.refuse_recv_at);
        try std.testing.expect((try pollOne(&backend)) == null);
        try closeDial(&backend, fd, 430 + i);
    }
}

test "onion listener setup ends with the exact cause of a refused control receive" {
    var backend = initBackend(std.testing.allocator, &.{});
    defer backend.deinit();
    backend.inner.refuse_recv_at = 0;

    const fd = try backend.openListener(.{ .onion = 0 });
    try backend.submitListenReady(410, fd);
    const ready = try waitFor(&backend, 410);
    try std.testing.expect(ready.result < 0);
    try std.testing.expectEqual(error.OutOfMemory, ready.failure.?);
    try std.testing.expectEqual(@as(?usize, null), backend.inner.refuse_recv_at);
    try std.testing.expect(!backend.listenerPending(fd));
    try std.testing.expect(backend.control_fd == null);
    try std.testing.expect((try pollOne(&backend)) == null);
}

test "onion completion cancellation retires target and cancel exactly once" {
    const chunks = [_][]const u8{
        &[_]u8{ 0x05, 0x00 },
        &[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 },
    };
    var backend = initBackend(std.testing.allocator, &chunks);
    defer backend.deinit();
    const fd = try openDial(&backend, 300);

    try backend.submitRecv(301, fd);
    try backend.submitCancel(302, 301, fd);
    const target_done = try waitFor(&backend, 301);
    const cancel_done = try waitFor(&backend, 302);
    try std.testing.expect(target_done.result < 0);
    try std.testing.expectEqual(@as(i32, 0), cancel_done.result);
    try std.testing.expect((try pollOne(&backend)) == null);
    try closeDial(&backend, fd, 303);
}

test "onion completion waits for pending operations after inner close completion" {
    const no_chunks = [_][]const u8{};
    var backend = initBackend(std.testing.allocator, &no_chunks);
    backend.inner.close_first = true;
    defer backend.deinit();

    const fd = try backend.startDial(400, target());
    _ = try backend.poll(&[_]completion.Completion{}, 0);
    try backend.submitClose(401, fd);
    const connect_done = try waitFor(&backend, 400);
    try std.testing.expect(connect_done.result < 0);
    const close_done = try waitFor(&backend, 401);
    try std.testing.expectEqual(@as(i32, 0), close_done.result);
    try std.testing.expect((try pollOne(&backend)) == null);
}

test "onion completion retains a closing connection until its borrowed receive recycles" {
    const chunks = [_][]const u8{
        &[_]u8{ 0x05, 0x00 },
        &[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 'x' },
    };
    var backend = initBackend(std.testing.allocator, &chunks);
    defer backend.deinit();

    const fd = try openDial(&backend, 450);
    try backend.submitRecv(451, fd);
    const recv = try waitFor(&backend, 451);
    try std.testing.expectEqualStrings("x", recv.borrowed.recvBytes().?);

    try backend.submitClose(452, fd);
    try std.testing.expect((try pollOne(&backend)) == null);
    backend.recycleBorrowed(recv);
    const closed = try waitFor(&backend, 452);
    try std.testing.expectEqual(@as(i32, 0), closed.result);
}

test "onion completion publishes backend listener metadata and holds control lifetime" {
    const control_reply = "250-ServiceID=" ++ service_id ++ "\r\n250-PrivateKey=ED25519-V3:key\r\n250 OK\r\n";
    const chunks = [_][]const u8{
        "2",
        "50 OK\r\n",
        control_reply,
    };
    var backend = initBackend(std.testing.allocator, &chunks);
    backend.inner.max_send_bytes = 1;
    defer backend.deinit();

    const listener_fd = try publishListener(&backend, 500);
    const address = try backend.listenerAddress(listener_fd);
    try std.testing.expectEqualSlices(u8, service_id, &address.onion);
    try std.testing.expect(Backend.listenerPort(address) == null);
    try std.testing.expect(std.mem.find(u8, backend.inner.sent_bytes.items, "127.0.0.1:4242") != null);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.closed_fds.items.len);

    try std.testing.expect(!backend.listenerPending(listener_fd));
    const stable_id = address.onion;
    try backend.submitClose(501, listener_fd);
    try std.testing.expectEqual(@as(usize, 1), backend.inner.closed_fds.items.len);
    try std.testing.expectEqual(@as(ScriptBackend.Fd, 20), backend.inner.closed_fds.items[0]);
    try std.testing.expectEqualSlices(u8, service_id, &stable_id);
    _ = try waitFor(&backend, 501);
}

test "onion completion bounds control setup and drains the timed-out operation" {
    var backend = Backend.initOnion(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .stall_control_connect = true,
    }, .{
        .socks = .socks,
        .control = .control,
        .setup_timeout_ms = 0,
    });
    defer backend.deinit();

    const fd = try backend.openListener(.{ .onion = 0 });
    try std.testing.expect(backend.listenerPending(fd));
    try backend.submitListenReady(600, fd);
    const ready = try waitFor(&backend, 600);
    try std.testing.expect(ready.result < 0);
    try std.testing.expectEqual(error.ControlSetupTimedOut, ready.failure.?);
    try std.testing.expect(backend.control_fd == null);
    try std.testing.expect(backend.inner.pending_connect_ud == null);
    try std.testing.expect(!backend.listenerPending(fd));
    try std.testing.expect((try pollOne(&backend)) == null);
}

test "onion completion returns a borrowed reply that lands past the setup deadline" {
    const chunks = [_][]const u8{"250 OK\r\n"};
    var backend = initBackend(std.testing.allocator, &chunks);
    defer backend.deinit();

    const fd = try backend.openListener(.{ .onion = 0 });
    try backend.submitListenReady(640, fd);
    // The deadline passes while the inner wait produces the reply, so the
    // record reaches the conversation already expired and still carrying
    // its borrowed buffer.
    backend.inner.expire_on_borrowed_poll = &backend.listener.setup.?.deadline_ms;
    const ready = try waitFor(&backend, 640);
    try std.testing.expect(ready.result < 0);
    try std.testing.expectEqual(error.ControlSetupTimedOut, ready.failure.?);
    try std.testing.expectEqual(@as(usize, 1), backend.inner.recycled_tokens.items.len);
    try std.testing.expect(!backend.listenerPending(fd));
    try std.testing.expect(backend.control_fd == null);
    try std.testing.expect((try pollOne(&backend)) == null);
}

test "onion completion closes a listener whose setup is still running" {
    var backend = Backend.initOnion(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .stall_control_connect = true,
    }, .{
        .socks = .socks,
        .control = .control,
    });
    defer backend.deinit();

    const fd = try backend.openListener(.{ .onion = 0 });
    try backend.submitListenReady(610, fd);
    try backend.submitClose(611, fd);
    const ready = try waitFor(&backend, 610);
    try std.testing.expect(ready.result < 0);
    try std.testing.expectEqual(error.ListenerClosed, ready.failure.?);
    const closed = try waitFor(&backend, 611);
    try std.testing.expectEqual(@as(i32, 0), closed.result);
    try std.testing.expect(backend.control_fd == null);
    try std.testing.expect(backend.inner.pending_connect_ud == null);
    try std.testing.expect(!backend.listenerPending(fd));
    try std.testing.expect((try pollOne(&backend)) == null);
}

test "onion completion answers a late ready seat with the settled outcome" {
    const control_reply = "250-ServiceID=" ++ service_id ++ "\r\n250 OK\r\n";
    const chunks = [_][]const u8{ "250 OK\r\n", control_reply };
    var backend = initBackend(std.testing.allocator, &chunks);
    defer backend.deinit();

    const fd = try publishListener(&backend, 620);
    try backend.submitListenReady(621, fd);
    const again = try waitFor(&backend, 621);
    try std.testing.expectEqual(@as(i32, 0), again.result);
    try std.testing.expect(!backend.listenerPending(fd));
    try backend.submitClose(622, fd);
    _ = try waitFor(&backend, 622);
}

test "onion completion fails the publish when the control connection refuses" {
    const chunks = [_][]const u8{ "250 OK\r\n", "500 Bogus\r\n" };
    var backend = initBackend(std.testing.allocator, &chunks);
    defer backend.deinit();

    const fd = try backend.openListener(.{ .onion = 0 });
    try backend.submitListenReady(630, fd);
    const ready = try waitFor(&backend, 630);
    try std.testing.expect(ready.result < 0);
    try std.testing.expectEqual(error.ControlRefused, ready.failure.?);
    try std.testing.expect(!backend.listenerPending(fd));
    try std.testing.expect((try pollOne(&backend)) == null);
}
