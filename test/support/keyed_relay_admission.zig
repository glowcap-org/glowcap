//! The fake-platform admission harness the keyed-relay completion adapter
//! tests drive: a scriptable platform backend whose dial, send, close, and
//! receive arms can be told to fail or park, plus the WebSocket upgrade that
//! opens a connection against it. Shared by the completion-adapter suites and
//! the completion-loop rendezvous tests in `keyed_relay_test.zig`, so the
//! adapter's behavior and the loop composed over it are proven against one
//! platform stub.

const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const net = pancake.net;
const keyed_relay = net.relay;

const Io = std.Io;
const ip = std.Io.net;

pub const frame_cap = 4096;

pub const AdmissionPlatform = struct {
    pub const Fd = i32;
    pub const adapter_depth = 0;
    pub const ConnectTarget = ip.IpAddress;

    pub fn applyKeepalive(_: *AdmissionPlatform, _: Fd, _: net.completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *AdmissionPlatform, _: Fd) pancake.ocapn.model.transport.WireFraming {
        return .byte_stream;
    }

    fail_dial: bool = false,
    fail_recv: bool = false,
    fail_send: bool = false,
    fail_close: bool = false,
    pending_connect: ?net.completion.Completion = null,
    pending_send: ?net.completion.Completion = null,
    pending_recv: ?net.completion.Completion = null,
    pending_cancel: ?net.completion.Completion = null,
    armed_recv_ud: ?u64 = null,
    pending_close: ?net.completion.Completion = null,
    race_mode: bool = false,
    race_connects: [16]net.completion.Completion = undefined,
    race_connect_head: u8 = 0,
    race_connect_len: u8 = 0,
    race_closes: [16]net.completion.Completion = undefined,
    race_close_head: u8 = 0,
    race_close_len: u8 = 0,
    dial_submits: usize = 0,
    next_dial_fd: Fd = 100,
    close_result: i32 = 0,
    close_before_recv: bool = false,
    emit_recv_no_buffer: bool = false,
    recv_payload: ?[]u8 = null,
    recv_token: u32 = 0,
    recv_attempts: usize = 0,
    recv_submits: usize = 0,
    send_submits: usize = 0,
    close_submits: usize = 0,
    poll_calls: usize = 0,
    close_calls: usize = 0,
    shutdown_calls: usize = 0,
    recycle_calls: usize = 0,
    last_recycled_token: u32 = 0,

    pub fn init(_: std.mem.Allocator, _: u16, _: u16, _: u32) !AdmissionPlatform {
        return .{};
    }

    pub fn deinit(_: *AdmissionPlatform) void {}
    pub fn openListener(_: *AdmissionPlatform, _: u16) !Fd {
        return 40;
    }
    pub const ListenerAddress = void;
    pub fn listenerAddress(_: *AdmissionPlatform, _: Fd) !ListenerAddress {}
    pub fn listenerPort(_: ListenerAddress) ?u16 {
        return null;
    }
    pub fn verifiedChannelKey(_: *AdmissionPlatform, _: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
        return null;
    }
    pub fn closeFd(self: *AdmissionPlatform, _: Fd) void {
        self.close_calls += 1;
    }
    pub fn shutdownFd(self: *AdmissionPlatform, _: Fd) void {
        self.shutdown_calls += 1;
    }
    pub fn recycleBorrowed(self: *AdmissionPlatform, comp: net.completion.Completion) void {
        self.recycle_calls += 1;
        self.last_recycled_token = comp.borrowed.token;
    }
    pub fn submitAccept(_: *AdmissionPlatform, _: u64, _: Fd) !void {}
    pub fn startDial(self: *AdmissionPlatform, user_data: u64, _: ConnectTarget) !Fd {
        if (self.fail_dial) return error.SubmitFailed;
        self.dial_submits += 1;
        if (self.race_mode) {
            const index = (self.race_connect_head + self.race_connect_len) % self.race_connects.len;
            self.race_connects[index] = .{ .user_data = user_data, .result = 0 };
            self.race_connect_len += 1;
            const fd = self.next_dial_fd;
            self.next_dial_fd += 1;
            return fd;
        }
        self.pending_connect = .{ .user_data = user_data, .result = 0 };
        return 41;
    }

    pub fn beginAddressRace(self: *AdmissionPlatform) void {
        self.pending_connect = null;
        self.race_mode = true;
        self.dial_submits = 0;
    }

    pub fn completeRecv(self: *AdmissionPlatform, bytes: []u8) !void {
        const user_data = self.armed_recv_ud orelse return error.RecvNotArmed;
        self.pending_recv = .{
            .user_data = user_data,
            .result = @intCast(bytes.len),
            .borrowed = .recv(bytes, self.recv_token),
        };
    }
    pub fn submitRecv(self: *AdmissionPlatform, user_data: u64, _: Fd) !void {
        self.recv_attempts += 1;
        if (self.fail_recv) return error.SubmitFailed;
        self.recv_submits += 1;
        self.armed_recv_ud = user_data;
        if (self.emit_recv_no_buffer) {
            self.pending_recv = .{
                .user_data = user_data,
                .result = -1,
                .recv_no_buffer = true,
            };
        } else if (self.recv_payload) |bytes| {
            self.pending_recv = .{
                .user_data = user_data,
                .result = @intCast(bytes.len),
                .borrowed = .recv(bytes, self.recv_token),
            };
            self.recv_payload = null;
        }
    }
    pub fn submitSend(self: *AdmissionPlatform, user_data: u64, _: Fd, bytes: []const u8) !void {
        if (self.fail_send) return error.SubmitFailed;
        self.send_submits += 1;
        self.pending_send = .{ .user_data = user_data, .result = @intCast(bytes.len) };
    }
    pub fn submitCancel(
        self: *AdmissionPlatform,
        cancel_user_data: u64,
        target_user_data: u64,
        _: Fd,
    ) !void {
        if (self.pending_recv == null) {
            const recv_ud = self.armed_recv_ud orelse return error.InvalidCancelTarget;
            if (recv_ud != target_user_data) return error.InvalidCancelTarget;
            self.pending_recv = .{ .user_data = target_user_data, .result = -1 };
        }
        self.pending_cancel = .{ .user_data = cancel_user_data, .result = 0 };
    }
    pub fn submitClose(self: *AdmissionPlatform, user_data: u64, _: Fd) !void {
        if (self.fail_close) return error.SubmitFailed;
        self.close_submits += 1;
        if (self.race_mode) {
            const index = (self.race_close_head + self.race_close_len) % self.race_closes.len;
            self.race_closes[index] = .{ .user_data = user_data, .result = self.close_result };
            self.race_close_len += 1;
            return;
        }
        if (self.pending_recv == null) {
            if (self.armed_recv_ud) |recv_ud|
                self.pending_recv = .{ .user_data = recv_ud, .result = -1 };
        }
        self.pending_close = .{ .user_data = user_data, .result = self.close_result };
    }
    pub fn poll(self: *AdmissionPlatform, out: []net.completion.Completion, _: i32) !usize {
        self.poll_calls += 1;
        if (out.len == 0) return 0;
        if (self.race_connect_len != 0) {
            out[0] = self.race_connects[self.race_connect_head];
            self.race_connect_head = (self.race_connect_head + 1) % @as(u8, self.race_connects.len);
            self.race_connect_len -= 1;
            return 1;
        }
        if (self.race_close_len != 0) {
            out[0] = self.race_closes[self.race_close_head];
            self.race_close_head = (self.race_close_head + 1) % @as(u8, self.race_closes.len);
            self.race_close_len -= 1;
            return 1;
        }
        if (self.pending_connect) |completion| {
            out[0] = completion;
            self.pending_connect = null;
            return 1;
        }
        if (self.pending_send) |completion| {
            out[0] = completion;
            self.pending_send = null;
            return 1;
        }
        if (self.close_before_recv) {
            if (self.pending_close) |completion| {
                out[0] = completion;
                self.pending_close = null;
                return 1;
            }
        }
        if (self.pending_recv) |completion| {
            out[0] = completion;
            self.pending_recv = null;
            self.armed_recv_ud = null;
            return 1;
        }
        if (self.pending_cancel) |completion| {
            out[0] = completion;
            self.pending_cancel = null;
            return 1;
        }
        if (self.pending_close) |completion| {
            out[0] = completion;
            self.pending_close = null;
            return 1;
        }
        return 0;
    }
};

pub const AdmissionBackend = keyed_relay.CompletionBackend(AdmissionPlatform);

pub fn admissionBackend(allocator: std.mem.Allocator) !AdmissionBackend {
    return AdmissionBackend.initWithRelay(
        allocator,
        8,
        1,
        64,
        .{
            .url = "ws://127.0.0.1:1/relay",
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x91)),
            .send_staging_bytes = frame_cap,
        },
    );
}

/// Direct adapter tests deliberately stop at intermediate states. Teardown
/// still honors the production lifecycle: request close through the public
/// backend contract and consume every completion before deinit.
pub fn deinitAdmissionBackend(backend: *AdmissionBackend) void {
    backend.platform.fail_close = false;
    var completions: [16]net.completion.Completion = undefined;
    var turns: usize = 0;
    while (backend.conns.count() != 0) : (turns += 1) {
        std.debug.assert(turns < 64);
        var keys = backend.conns.keyIterator();
        const id = (keys.next() orelse unreachable).*;
        const conn = backend.conns.get(id) orelse unreachable;
        if (conn.external_close_ud == null) {
            const fd: AdmissionBackend.Fd = @bitCast(@as(u32, 0x8000_0000) | id);
            backend.shutdownFd(fd);
            backend.submitClose(0x7fff_ffff_0000_0000 | @as(u64, id), fd) catch unreachable;
        }
        const n = backend.poll(&completions, 0) catch unreachable;
        for (completions[0..n]) |completion| {
            if (completion.borrowed.active()) backend.recycleBorrowed(completion);
        }
    }
    backend.deinit();
}

pub fn startUpgradeRelay(backend: *AdmissionBackend) !AdmissionBackend.Fd {
    const designator = @as([64]u8, @splat('a'));
    const fd = try backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    const conn = backend.conns.get(1).?;
    try std.testing.expectEqual(.reading_upgrade, conn.state);
    try std.testing.expect(conn.pending.recv);
    return fd;
}

pub fn openAdmissionRelay(backend: *AdmissionBackend) !AdmissionBackend.Fd {
    const prior_recycle_calls = backend.platform.recycle_calls;
    const prior_recycled_token = backend.platform.last_recycled_token;
    const fd = try startUpgradeRelay(backend);
    const conn = backend.conns.get(1).?;
    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{conn.expected_accept[0..]},
    );
    try backend.platform.completeRecv(response);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 7), completions[0].user_data);
    try std.testing.expectEqual(.open, conn.state);

    // Post-open unit tests inject one operation at a time. Retire the mock's
    // background receive arm without manufacturing protocol state; the helper
    // above has already driven connect, upgrade send, and upgrade receive.
    conn.pending.recv = false;
    backend.platform.armed_recv_ud = null;
    backend.platform.pending_recv = null;
    backend.ready.deinit(backend.allocator);
    backend.ready = .{};
    backend.platform.poll_calls = 0;
    backend.platform.recv_submits = 0;
    backend.platform.send_submits = 0;
    backend.platform.recycle_calls = prior_recycle_calls;
    backend.platform.last_recycled_token = prior_recycled_token;
    return fd;
}
