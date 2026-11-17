//! A scripted onion transport for the onion completion tests: a recorded
//! backend that replays receive chunks, plus the dial and listener drivers the
//! suites share.

const std = @import("std");
const handshake = @import("handshake.zig");
const glowcap = @import("glowcap");

const completion = glowcap.net.completion;
const onion = glowcap.net.onion;
const engine = glowcap.ocapn.engine;

pub const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

pub const ScriptBackend = struct {
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
    /// The scripted receive index that completes as a refused buffer growth:
    /// negative result, `OutOfMemory`, no borrow, no `recv_no_buffer`. This is
    /// the epoll backend's producer shape, injected here so the onion
    /// consumers are proved. The allocator refusal itself is proved at the
    /// epoll pool.
    refuse_recv_at: ?usize = null,
    /// A deadline to expire the moment this poll hands back a borrowed
    /// receive, after the turn's own deadline check has already passed.
    expire_on_borrowed_poll: ?*i64 = null,

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

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
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
        if (self.refuse_recv_at == self.recv_index) {
            self.refuse_recv_at = null;
            try self.ready.append(self.allocator, .{
                .user_data = user_data,
                .result = -1,
                .failure = error.OutOfMemory,
            });
            return;
        }
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

    /// A scripted listener binds at `openListener`. Nothing pends here. The
    /// onion adapter's own publish conversation reports through its row.
    pub fn listenerPending(_: *const ScriptBackend, _: Fd) bool {
        return false;
    }

    pub fn waitBoundMs(_: *const ScriptBackend, requested_ms: i32) i32 {
        return requested_ms;
    }

    /// No submission queue here, so a peek is a zero-timeout poll.
    pub fn peek(self: *ScriptBackend, out: []completion.Completion) !usize {
        return self.poll(out, 0);
    }

    pub fn poll(self: *ScriptBackend, out: []completion.Completion, _: i32) !usize {
        const n = @min(out.len, self.ready.items.len);
        @memcpy(out[0..n], self.ready.items[0..n]);
        if (self.expire_on_borrowed_poll) |deadline| for (out[0..n]) |comp| if (comp.borrowed.active()) {
            deadline.* = 0;
            self.expire_on_borrowed_poll = null;
        };
        const rest = self.ready.items.len - n;
        @memmove(self.ready.items[0..rest], self.ready.items[n..]);
        self.ready.shrinkRetainingCapacity(rest);
        return n;
    }
};

pub const Backend = onion.completion.CompletionBackend(ScriptBackend);

pub fn initBackend(allocator: std.mem.Allocator, chunks: []const []const u8) Backend {
    return Backend.initOnion(allocator, .{
        .allocator = allocator,
        .recv_chunks = chunks,
    }, .{ .socks = .socks, .control = .control });
}

pub fn target() Backend.ConnectTarget {
    var id: [service_id.len]u8 = undefined;
    @memcpy(&id, service_id);
    return .{ .onion = .{ .service_id = id } };
}

pub fn pollOne(backend: *Backend) !?completion.Completion {
    var out: [1]completion.Completion = undefined;
    const n = try backend.poll(&out, 0);
    return if (n == 0) null else out[0];
}

pub fn waitFor(backend: *Backend, user_data: u64) !completion.Completion {
    var turns: usize = 0;
    while (turns < 1024) : (turns += 1) {
        if (try pollOne(backend)) |comp| {
            if (comp.user_data == user_data) return comp;
            return error.UnexpectedCompletion;
        }
    }
    return error.CompletionTimeout;
}

pub fn openDial(backend: *Backend, connect_ud: u64) !Backend.Fd {
    const fd = try backend.startDial(connect_ud, target());
    const connected = try waitFor(backend, connect_ud);
    try std.testing.expectEqual(@as(i32, 0), connected.result);
    return fd;
}

/// Open the onion listener and drive its pending publish conversation to a
/// live service, collecting the runtime's ready seat on the way.
pub fn publishListener(backend: *Backend, ready_ud: u64) !Backend.Fd {
    const fd = try backend.openListener(.{ .onion = 0 });
    try std.testing.expect(backend.listenerPending(fd));
    try backend.submitListenReady(ready_ud, fd);
    var turns: usize = 0;
    while (turns < 1024) : (turns += 1) {
        if (try pollOne(backend)) |comp| {
            if (comp.user_data != ready_ud) return error.UnexpectedCompletion;
            try std.testing.expectEqual(@as(i32, 0), comp.result);
            return fd;
        }
    }
    return error.CompletionTimeout;
}

pub fn closeDial(backend: *Backend, fd: Backend.Fd, close_ud: u64) !void {
    try backend.submitClose(close_ud, fd);
    const closed = try waitFor(backend, close_ud);
    try std.testing.expectEqual(@as(i32, 0), closed.result);
}

pub fn makePeer(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    return handshake.stubPeer(allocator);
}
