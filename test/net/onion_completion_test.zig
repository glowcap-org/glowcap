const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const test_host = @import("../support/core_host.zig");

const net = glowcap.net;
const completion = glowcap.net.completion;
const onion = glowcap.net.onion;
const engine = glowcap.ocapn.engine;
const driver = glowcap.driver;

const Host = driver.core.Host;
const NativeOnionBridge = driver.Bridge(net.OnionLoop);

const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

const ScriptBackend = struct {
    pub const Fd = i32;
    pub const adapter_depth = 0;
    pub const ConnectTarget = enum { socks, control, plain };
    pub const ListenerAddress = u16;

    const Send = struct {
        user_data: u64,
        fd: Fd,
        ptr: [*]const u8,
        len: usize,
    };

    allocator: std.mem.Allocator,
    ready: std.ArrayList(completion.Completion) = .empty,
    sends: std.ArrayList(Send) = .empty,
    sent_bytes: std.ArrayList(u8) = .empty,
    closed_fds: std.ArrayList(Fd) = .empty,
    recycled_tokens: std.ArrayList(u32) = .empty,
    recv_chunks: []const []const u8 = &.{},
    recv_index: usize = 0,
    next_route_id: u32 = 1,
    next_fd: Fd = 20,
    pending_recv_ud: ?u64 = null,
    pending_connect_ud: ?u64 = null,
    max_send_bytes: usize = std.math.maxInt(usize),
    refuse_next_send: bool = false,
    close_first: bool = false,
    stall_control_connect: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        _: u16,
        _: u16,
        _: u32,
    ) !ScriptBackend {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ScriptBackend) void {
        self.ready.deinit(self.allocator);
        self.sends.deinit(self.allocator);
        self.sent_bytes.deinit(self.allocator);
        self.closed_fds.deinit(self.allocator);
        self.recycled_tokens.deinit(self.allocator);
    }

    pub fn openListener(_: *ScriptBackend, _: u16) !Fd {
        return 10;
    }

    pub fn listenerAddress(_: *ScriptBackend, fd: Fd) !ListenerAddress {
        if (fd != 10) return error.InvalidListener;
        return 4242;
    }

    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address;
    }

    pub fn startDial(self: *ScriptBackend, user_data: u64, target_value: ConnectTarget) !Fd {
        const fd = self.next_fd;
        self.next_fd += 1;
        if (target_value == .control and self.stall_control_connect) {
            self.pending_connect_ud = user_data;
            return fd;
        }
        try self.ready.append(self.allocator, .{ .user_data = user_data, .result = 0 });
        return fd;
    }

    pub fn submitAccept(_: *ScriptBackend, _: u64, _: Fd) !void {}

    pub fn submitRecv(self: *ScriptBackend, user_data: u64, _: Fd) !void {
        if (self.pending_recv_ud != null) return error.AlreadyReading;
        if (self.recv_index == self.recv_chunks.len) {
            self.pending_recv_ud = user_data;
            return;
        }
        const bytes = self.recv_chunks[self.recv_index];
        self.recv_index += 1;
        const token = self.next_route_id;
        self.next_route_id += 1;
        try self.ready.append(self.allocator, .{
            .user_data = user_data,
            .result = @intCast(bytes.len),
            .borrowed = .recv(bytes, token),
        });
    }

    pub fn submitSend(self: *ScriptBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        if (self.refuse_next_send) {
            self.refuse_next_send = false;
            return error.SubmitPressure;
        }
        const sent = @min(bytes.len, self.max_send_bytes);
        try self.sends.append(self.allocator, .{
            .user_data = user_data,
            .fd = fd,
            .ptr = bytes.ptr,
            .len = bytes.len,
        });
        try self.sent_bytes.appendSlice(self.allocator, bytes[0..sent]);
        try self.ready.append(self.allocator, .{ .user_data = user_data, .result = @intCast(sent) });
    }

    pub fn submitCancel(
        self: *ScriptBackend,
        cancel_user_data: u64,
        target_user_data: u64,
        _: Fd,
    ) !void {
        if (self.pending_recv_ud != target_user_data) return error.InvalidCancelTarget;
        self.pending_recv_ud = null;
        try self.ready.append(self.allocator, .{ .user_data = target_user_data, .result = -1 });
        try self.ready.append(self.allocator, .{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn shutdownFd(_: *ScriptBackend, _: Fd) void {}

    pub fn submitClose(self: *ScriptBackend, user_data: u64, _: Fd) !void {
        if (self.pending_connect_ud) |connect_ud| {
            self.pending_connect_ud = null;
            try self.ready.append(self.allocator, .{ .user_data = connect_ud, .result = -1 });
        }
        if (self.pending_recv_ud) |recv_ud| {
            self.pending_recv_ud = null;
            try self.ready.append(self.allocator, .{ .user_data = recv_ud, .result = -1 });
        }
        const close = completion.Completion{ .user_data = user_data, .result = 0 };
        if (self.close_first)
            try self.ready.insert(self.allocator, 0, close)
        else
            try self.ready.append(self.allocator, close);
    }

    pub fn closeFd(self: *ScriptBackend, fd: Fd) void {
        self.closed_fds.append(self.allocator, fd) catch unreachable;
    }

    pub fn recycleBorrowed(self: *ScriptBackend, comp: completion.Completion) void {
        self.recycled_tokens.append(self.allocator, comp.borrowed.token) catch unreachable;
    }

    pub fn verifiedChannelKey(_: *ScriptBackend, _: Fd) ?[32]u8 {
        return null;
    }

    pub fn poll(self: *ScriptBackend, out: []completion.Completion, _: i32) !usize {
        const n = @min(out.len, self.ready.items.len);
        @memcpy(out[0..n], self.ready.items[0..n]);
        const rest = self.ready.items.len - n;
        std.mem.copyForwards(completion.Completion, self.ready.items[0..rest], self.ready.items[n..]);
        self.ready.shrinkRetainingCapacity(rest);
        return n;
    }
};

const Backend = onion.completion.CompletionBackend(ScriptBackend);

fn initBackend(allocator: std.mem.Allocator, chunks: []const []const u8) Backend {
    return Backend.initOnion(allocator, .{
        .allocator = allocator,
        .recv_chunks = chunks,
    }, .{ .socks = .socks, .control = .control });
}

fn target() Backend.ConnectTarget {
    var id: [service_id.len]u8 = undefined;
    @memcpy(&id, service_id);
    return .{ .onion = .{ .service_id = id } };
}

fn pollOne(backend: *Backend) !?completion.Completion {
    var out: [1]completion.Completion = undefined;
    const n = try backend.poll(&out, 0);
    return if (n == 0) null else out[0];
}

fn waitFor(backend: *Backend, user_data: u64) !completion.Completion {
    var turns: usize = 0;
    while (turns < 1024) : (turns += 1) {
        if (try pollOne(backend)) |comp| {
            if (comp.user_data == user_data) return comp;
            return error.UnexpectedCompletion;
        }
    }
    return error.CompletionTimeout;
}

fn openDial(backend: *Backend, connect_ud: u64) !Backend.Fd {
    const fd = try backend.startDial(connect_ud, target());
    const connected = try waitFor(backend, connect_ud);
    try std.testing.expectEqual(@as(i32, 0), connected.result);
    return fd;
}

fn closeDial(backend: *Backend, fd: Backend.Fd, close_ud: u64) !void {
    try backend.submitClose(close_ud, fd);
    const closed = try waitFor(backend, close_ud);
    try std.testing.expectEqual(@as(i32, 0), closed.result);
}

fn makePeer(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

test "native OnionLoop composes the onion adapter, completion Loop, and driver Bridge" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    comptime {
        std.debug.assert(net.OnionBackend == onion.completion.CompletionBackend(net.Backend));
        std.debug.assert(net.OnionDialResolver == onion.completion.DialResolver(net.tcp.DialResolver, net.Backend));
        std.debug.assert(net.OnionLoop == completion.Loop(net.OnionBackend, net.OnionDialResolver));
    }

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var host = test_host.init(allocator, @as([32]u8, @splat(0x81)), Host.Options.withFrameCap(4096));
    defer host.deinit();

    const platform = try net.Backend.init(allocator, 8, 1, 4096);
    const socks = try std.Io.net.IpAddress.parse("127.0.0.1", 9050);
    const backend = net.OnionBackend.initOnion(allocator, platform, .{ .socks = socks });

    var loop: net.OnionLoop = undefined;
    var bridge = NativeOnionBridge.init(allocator, &host, threaded.io(), &loop, .{});
    defer bridge.deinit();

    loop = try net.OnionLoop.initWithBackend(
        allocator,
        backend,
        NativeOnionBridge.makePeer,
        @ptrCast(&bridge),
        NativeOnionBridge.hookOptions(.{
            .max_conns = 1,
            .listen = null,
        }),
    );
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

    const address = loop.listenerAddress().?;
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

    const listener_fd = try backend.openListener(0);
    const address = try backend.listenerAddress(listener_fd);
    try std.testing.expectEqualSlices(u8, service_id, &address);
    try std.testing.expect(Backend.listenerPort(address) == null);
    try std.testing.expect(std.mem.indexOf(u8, backend.inner.sent_bytes.items, "127.0.0.1:4242") != null);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.closed_fds.items.len);

    const stable_id = address;
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

    try std.testing.expectError(error.ControlSetupTimedOut, backend.openListener(0));
    try std.testing.expect(backend.control_fd == null);
    try std.testing.expect(backend.inner.pending_connect_ud == null);
    try std.testing.expect((try pollOne(&backend)) == null);
}
