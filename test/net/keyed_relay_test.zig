//! The keyed-relay netlayer: the RFC 6455 client codec's refusals, the relay
//! URL grammar, and the headline loopback — a native peer registers at an
//! in-process relay (`test/support/ws_relay.zig`), another native peer cold
//! dials its key designator through the relay's rendezvous leg, and a
//! bootstrap fetch round-trips over the bridged WebSocket pair. The relay
//! pings the parked registration before the dial and the listener answers in
//! place, so the wait loop's control-frame handling is on the proven path.
//! The live sibling against the Deno reference relay is
//! `zig build zig-keyed-relay-rendezvous`.

const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;
const keyed_relay = net.keyed_relay;
const ws_relay = @import("../support/ws_relay.zig");
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const wait = @import("../support/wait.zig");

const Io = std.Io;
const ip = std.Io.net;

const frame_cap = 4096;

// --- Codec units -----------------------------------------------------------

test "acceptKey reproduces the RFC 6455 worked example" {
    var out: [28]u8 = undefined;
    keyed_relay.acceptKey(&out, "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", out[0..]);
}

test "upgrade response requires the full RFC 6455 handshake" {
    var expected: [28]u8 = undefined;
    keyed_relay.acceptKey(&expected, "dGhlIHNhbXBsZSBub25jZQ==");
    const valid =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    try std.testing.expect(keyed_relay.validUpgradeResponse(valid, &expected));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        "XXXXXXXXX101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nnot-a-header",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade : websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nSec-WebSocket-Accept: wrong",
        &expected,
    ));
    // The client offered neither field; a server cannot unilaterally install
    // extension bits or subprotocol semantics this endpoint does not speak.
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nSec-WebSocket-Extensions: permessage-deflate",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nSec-WebSocket-Protocol: ocapn",
        &expected,
    ));
}

fn headerOf(bytes: []const u8) keyed_relay.FrameError!keyed_relay.FrameHeader {
    var r = Io.Reader.fixed(bytes);
    return keyed_relay.readFrameHeader(&r);
}

test "readFrameHeader accepts the plain server shapes" {
    // FIN binary, 5-byte payload.
    const small = try headerOf(&.{ 0x82, 0x05 });
    try std.testing.expectEqual(keyed_relay.Opcode.binary, small.opcode);
    try std.testing.expectEqual(@as(u64, 5), small.len);
    try std.testing.expect(small.fin);

    // 16-bit extended length.
    const mid = try headerOf(&.{ 0x82, 126, 0x01, 0x2c });
    try std.testing.expectEqual(@as(u64, 300), mid.len);

    // 64-bit extended length.
    const big = try headerOf(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70 });
    try std.testing.expectEqual(@as(u64, 70000), big.len);

    // Non-final binary then a continuation: fragmentation streams through.
    const frag = try headerOf(&.{ 0x02, 0x05 });
    try std.testing.expect(!frag.fin);
    const cont = try headerOf(&.{ 0x80, 0x03 });
    try std.testing.expectEqual(keyed_relay.Opcode.continuation, cont.opcode);
}

test "readFrameHeader fails closed on every hostile shape" {
    // A reserved bit set (no extension negotiated).
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0xc2, 0x05 }));
    // A masked server frame (RFC 6455 forbids it).
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x82, 0x85, 1, 2, 3, 4 }));
    // A text frame on a binary protocol.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x81, 0x05 }));
    // An unknown opcode.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x83, 0x05 }));
    // A control frame past the 125-byte cap.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x89, 126, 0x00, 0x80 }));
    // A fragmented ping.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x09, 0x05 }));
    // A 64-bit length with the sign bit set.
    try std.testing.expectError(
        error.ProtocolViolation,
        headerOf(&.{ 0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 1 }),
    );
    // Extended lengths must use the minimal encoding (RFC 6455 section 5.2).
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x82, 126, 0, 125 }));
    try std.testing.expectError(
        error.ProtocolViolation,
        headerOf(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0, 0xff, 0xff }),
    );
    // A close payload cannot contain only half of its two-byte status code.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x88, 1 }));
    // Truncation mid-header.
    try std.testing.expectError(error.Truncated, headerOf(&.{0x82}));
    try std.testing.expectError(error.Truncated, headerOf(&.{ 0x82, 126, 0x01 }));
}

test "close payload validates status codes and UTF-8 reasons" {
    try keyed_relay.validateClosePayload(&.{});
    try keyed_relay.validateClosePayload(&.{ 0x03, 0xe8 }); // 1000
    try keyed_relay.validateClosePayload(&.{ 0x0b, 0xb8, 'b', 'y', 'e' }); // 3000
    try std.testing.expectError(error.ProtocolViolation, keyed_relay.validateClosePayload(&.{0x03}));
    try std.testing.expectError(error.ProtocolViolation, keyed_relay.validateClosePayload(&.{ 0x03, 0xed })); // 1005
    try std.testing.expectError(error.ProtocolViolation, keyed_relay.validateClosePayload(&.{ 0x07, 0xd0 })); // 2000
    try std.testing.expectError(
        error.ProtocolViolation,
        keyed_relay.validateClosePayload(&.{ 0x03, 0xe8, 0xff }),
    );
}

test "writeFrameHeader emits the masked client shapes readFrameHeader's mirror expects" {
    const mask = [4]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };
    var buf: [keyed_relay.max_header_len]u8 = undefined;

    const small = try keyed_relay.writeFrameHeader(&buf, .binary, 5, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x85, 0xa1, 0xb2, 0xc3, 0xd4 }, small);

    const mid = try keyed_relay.writeFrameHeader(&buf, .binary, 300, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0xfe, 0x01, 0x2c, 0xa1, 0xb2, 0xc3, 0xd4 }, mid);

    const big = try keyed_relay.writeFrameHeader(&buf, .binary, 70000, mask);
    try std.testing.expectEqual(@as(usize, keyed_relay.max_header_len), big.len);
    try std.testing.expectEqual(@as(u8, 0x82), big[0]);
    try std.testing.expectEqual(@as(u8, 0xff), big[1]);

    try std.testing.expectError(
        error.ControlPayloadTooLarge,
        keyed_relay.writeFrameHeader(&buf, .ping, 126, mask),
    );
    _ = try keyed_relay.writeFrameHeader(&buf, .binary, std.math.maxInt(i64), mask);
    try std.testing.expectError(
        error.PayloadTooLarge,
        keyed_relay.writeFrameHeader(&buf, .binary, @as(u64, std.math.maxInt(i64)) + 1, mask),
    );
}

test "RelayUrl.parse admits ws IP-literal endpoints and refuses the rest" {
    const good = try keyed_relay.RelayUrl.parse("ws://127.0.0.1:8000/relay");
    try std.testing.expectEqualStrings("127.0.0.1", good.host);
    try std.testing.expectEqual(@as(u16, 8000), good.port);
    try std.testing.expectEqualStrings("/relay", good.path);

    const bare = try keyed_relay.RelayUrl.parse("ws://[::1]:9000");
    try std.testing.expectEqualStrings("::1", bare.host);
    try std.testing.expectEqualStrings("[::1]", bare.authority_host);
    try std.testing.expectEqualStrings("", bare.path);

    const queried = try keyed_relay.RelayUrl.parse("ws://127.0.0.1:8000/relay?deployment=local");
    try std.testing.expectEqualStrings("/relay?deployment=local", queried.path);

    // The scheme is `ws` only (cleartext channel, keyed handshake carries the
    // authentication); anything else refuses.
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("wss://127.0.0.1:1/x"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("http://127.0.0.1:1/x"));
    // The native tier resolves no names, and the port is explicit.
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://relay.example:80/x"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://127.0.0.1/x"));
    // HTTP authorities require brackets around IPv6, and the path is emitted
    // verbatim as the request target: controls, whitespace, and fragments are
    // never valid deployment configuration.
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://::1:9000/relay"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://127.0.0.1:80/relay\r\nInjected: yes"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://127.0.0.1:80/a path"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://127.0.0.1:80/relay#local"));
}

test "keyed-relay resident owns retained URL configuration" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var url_storage = "ws://127.0.0.1:80/r".*;
    var resident = try keyed_relay.Resident.init(std.testing.allocator, threaded.io(), &url_storage);
    defer resident.deinit();

    @memset(&url_storage, 'x');
    try std.testing.expectEqualStrings("127.0.0.1", resident.relay_url.host);
    try std.testing.expectEqualStrings("/r", resident.relay_url.path);
}

test "relay resident profile selects the complete netlayer contract" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var clear = try keyed_relay.Resident.initProfile(
        allocator,
        threaded.io(),
        "ws://127.0.0.1:8000/relay",
        .keyed,
    );
    defer clear.deinit();
    try std.testing.expectEqualStrings(model.transport.keyed_relay, clear.netlayer().transportName());

    var sealed_resident = try keyed_relay.Resident.initProfile(
        allocator,
        threaded.io(),
        "ws://127.0.0.1:8000/relay",
        .noise,
    );
    defer sealed_resident.deinit();
    try std.testing.expectEqualStrings(model.transport.noise_relay, sealed_resident.netlayer().transportName());

    var provider: keyed_relay.Provider = .{};
    try provider.init(allocator, threaded.io(), "ws://127.0.0.1:8000/relay");
    defer provider.deinit();
    const layers = provider.netlayers();
    try std.testing.expectEqual(@as(usize, 2), layers.len);
    try std.testing.expectEqualStrings(model.transport.keyed_relay, layers[0].transportName());
    try std.testing.expectEqualStrings(model.transport.noise_relay, layers[1].transportName());
}

const AdmissionPlatform = struct {
    pub const Fd = i32;
    pub const adapter_depth = 0;
    pub const ConnectTarget = ip.IpAddress;

    fail_dial: bool = false,
    fail_send: bool = false,
    fail_close: bool = false,
    pending_connect: ?net.completion.Completion = null,
    pending_send: ?net.completion.Completion = null,
    pending_recv: ?net.completion.Completion = null,
    pending_cancel: ?net.completion.Completion = null,
    armed_recv_ud: ?u64 = null,
    pending_close: ?net.completion.Completion = null,
    close_result: i32 = 0,
    close_before_recv: bool = false,
    emit_recv_no_buffer: bool = false,
    recv_payload: ?[]u8 = null,
    recv_token: u32 = 0,
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
    pub fn recycleRecv(self: *AdmissionPlatform, comp: net.completion.Completion) void {
        self.recycle_calls += 1;
        self.last_recycled_token = comp.recv_token;
    }
    pub fn submitAccept(_: *AdmissionPlatform, _: u64, _: Fd) !void {}
    pub fn startDial(self: *AdmissionPlatform, user_data: u64, _: ConnectTarget) !Fd {
        if (self.fail_dial) return error.SubmitFailed;
        self.pending_connect = .{ .user_data = user_data, .result = 0 };
        return 41;
    }

    fn completeRecv(self: *AdmissionPlatform, bytes: []u8) !void {
        const user_data = self.armed_recv_ud orelse return error.RecvNotArmed;
        self.pending_recv = .{
            .user_data = user_data,
            .result = @intCast(bytes.len),
            .recv_bytes = bytes,
            .recv_token = self.recv_token,
        };
    }
    pub fn submitRecv(self: *AdmissionPlatform, user_data: u64, _: Fd) !void {
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
                .recv_bytes = bytes,
                .recv_token = self.recv_token,
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
        if (self.pending_recv == null) {
            if (self.armed_recv_ud) |recv_ud|
                self.pending_recv = .{ .user_data = recv_ud, .result = -1 };
        }
        self.pending_close = .{ .user_data = user_data, .result = self.close_result };
    }
    pub fn poll(self: *AdmissionPlatform, out: []net.completion.Completion, _: i32) !usize {
        self.poll_calls += 1;
        if (out.len == 0) return 0;
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

const AdmissionBackend = keyed_relay.CompletionBackend(AdmissionPlatform);
const keyed_relay_connection_state_bytes: usize = 264;

test "keyed-relay completion connection state has a measured footprint" {
    try std.testing.expectEqual(keyed_relay_connection_state_bytes, AdmissionBackend.connection_state_bytes);
}

fn admissionBackend(allocator: std.mem.Allocator) !AdmissionBackend {
    return AdmissionBackend.initWithRelay(
        allocator,
        8,
        1,
        64,
        .{
            .url = "ws://127.0.0.1:1/relay",
            .entropy_seed = [_]u8{0x91} ** std.Random.DefaultCsprng.secret_seed_length,
            .send_staging_bytes = frame_cap,
        },
    );
}

test "keyed-relay completion rejects send staging too small for control frames" {
    try std.testing.expectError(
        error.InvalidSendStagingBytes,
        AdmissionBackend.initWithRelay(std.testing.allocator, 8, 1, 64, .{
            .url = "ws://127.0.0.1:1/relay",
            .entropy_seed = [_]u8{0x91} ** std.Random.DefaultCsprng.secret_seed_length,
            .send_staging_bytes = 0,
        }),
    );
}

/// Direct adapter tests deliberately stop at intermediate states. Teardown
/// still honors the production lifecycle: request close through the public
/// backend contract and consume every completion before deinit.
fn deinitAdmissionBackend(backend: *AdmissionBackend) void {
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
            if (completion.recv_bytes != null) backend.recycleRecv(completion);
        }
    }
    backend.deinit();
}

fn startUpgradeRelay(backend: *AdmissionBackend) !AdmissionBackend.Fd {
    const designator = [_]u8{'a'} ** 64;
    const fd = try backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    const conn = backend.conns.get(1).?;
    try std.testing.expectEqual(.reading_upgrade, conn.state);
    try std.testing.expect(conn.pending.recv);
    return fd;
}

fn openAdmissionRelay(backend: *AdmissionBackend) !AdmissionBackend.Fd {
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

test "keyed-relay refused dial releases construction state and reuses its handle" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const designator = [_]u8{'a'} ** 64;

    backend.platform.fail_dial = true;
    try std.testing.expectError(
        error.SubmitFailed,
        backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = null } }),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(u32, 1), backend.next_id);

    backend.platform.fail_dial = false;
    const fd = try backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8000_0001))), fd);
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());
}

test "keyed-relay refused send submission restores the frame queue and user-data seat" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.fail_send = true;
    try std.testing.expectError(error.SubmitFailed, backend.submitSend(17, fd, "payload"));
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
    try std.testing.expectEqual(@as(usize, 0), conn.ws_out.items.len);

    backend.platform.fail_send = false;
    try backend.submitSend(17, fd, "payload");
    try std.testing.expectEqual(@as(?u64, 17), conn.external_send_ud);
    try std.testing.expect(conn.ws_out.items.len > 0);
}

test "keyed-relay refused recv admission consumes no payload and installs no seat" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x03, 'a', 'b', 'c' });

    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    const original = backend.allocator;
    backend.allocator = fixed.allocator();
    try std.testing.expectError(error.OutOfMemory, backend.submitRecv(23, fd));
    backend.allocator = original;

    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(u64, 0), conn.data_remaining);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x03, 'a', 'b', 'c' }, conn.raw_in.items);

    try backend.submitRecv(23, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 23), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "abc", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
}

test "keyed-relay buffered work still services delegated platform completions" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'a' });
    try backend.submitRecv(24, fd);
    backend.platform.pending_send = .{ .user_data = 25, .result = 1 };

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 24), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.poll_calls);
    try std.testing.expect(backend.platform.pending_send == null);
    backend.recycleRecv(completions[0]);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 25), completions[0].user_data);
}

test "keyed-relay allocator pressure does not hide earned completions" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'a' });
    try backend.submitRecv(26, fd);
    backend.platform.pending_send = .{ .user_data = 27, .result = 1 };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var completions: [1]net.completion.Completion = undefined;
    {
        const original = backend.allocator;
        backend.allocator = failing.allocator();
        defer backend.allocator = original;
        try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    }

    try std.testing.expectEqual(@as(u64, 26), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.poll_calls);
    try std.testing.expect(backend.platform.pending_send != null);
    backend.recycleRecv(completions[0]);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 27), completions[0].user_data);
}

test "keyed-relay accepted close retries wrapped close refusal" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    conn.external_recv_ud = 31;
    conn.external_send_ud = 32;
    conn.external_send_len = 9;

    backend.platform.fail_close = true;
    try backend.submitClose(33, fd);

    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
    try std.testing.expectEqual(@as(?u64, 33), conn.external_close_ud);
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expectEqual(@as(usize, 2), backend.ready.len());

    var completions: [3]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.close_retries.contains(conn));
    try std.testing.expectEqual(@as(usize, 1), backend.close_retries.count);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.shutdown_calls);

    backend.platform.fail_close = false;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 33), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay direct release retires a refused wrapped close" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.fail_close = true;
    try backend.submitClose(33, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.close_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 1), backend.close_retries.head);

    // The direct release contract has no caller completion to publish. Model
    // that owner handoff after proving the public close path queued the retry.
    conn.external_close_ud = null;
    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.close_retries.count);
    try std.testing.expectEqual(@as(u32, 0), backend.close_retries.head);
    try std.testing.expectEqual(@as(u32, 0), backend.close_retries.tail);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay reserves user completions before consuming a platform send" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try backend.submitSend(41, fd, "payload");

    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    const original = backend.allocator;
    backend.allocator = fixed.allocator();
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectError(error.OutOfMemory, backend.poll(&completions, 0));
    backend.allocator = original;

    // Allocation refusal happened before `platform.poll`, so the terminal send
    // record and the caller's seat are both still available for an exact retry.
    try std.testing.expectEqual(@as(usize, 0), backend.platform.poll_calls);
    try std.testing.expectEqual(@as(?u64, 41), conn.external_send_ud);
    try std.testing.expect(backend.platform.pending_send != null);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 41), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 7), completions[0].result);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
}

test "keyed-relay records recv-buffer starvation without allocating" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(42, fd);
    try backend.ready.ensureUnusedCapacity(backend.allocator, 256 * 3);

    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    const original = backend.allocator;
    backend.allocator = fixed.allocator();
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    backend.allocator = original;

    try std.testing.expectEqual(@as(usize, 1), backend.platform.poll_calls);
    try std.testing.expectEqual(@as(u32, 1), backend.recv_retries.head);
}

test "keyed-relay recycles delegated and relayed recv buffers to their owning pools" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);

    var delegated_bytes = [_]u8{0xaa};
    backend.recycleRecv(.{
        .user_data = 1,
        .result = 1,
        .recv_bytes = &delegated_bytes,
        .recv_token = 7,
    });
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(u32, 7), backend.platform.last_recycled_token);

    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'a' });
    try backend.submitRecv(2, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);

    // The relay pool has one seat. Reusing it proves the tagged completion was
    // returned there rather than forwarded to the wrapped platform pool.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'b' });
    try backend.submitRecv(3, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "b", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
}

test "keyed-relay lends platform payload directly and copies only a coalesced tail" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    // Two complete server frames arrive in one wrapped-platform buffer. The
    // first payload can borrow that buffer directly; the second frame must move
    // to the spill before the outer Loop recycles the original token.
    var wire = [_]u8{ 0x82, 0x01, 'a', 0x82, 0x01, 'b' };
    backend.platform.recv_payload = &wire;
    backend.platform.recv_token = 29;

    try backend.submitRecv(81, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].recv_bytes.?);
    try std.testing.expectEqual(@intFromPtr(&wire[2]), @intFromPtr(completions[0].recv_bytes.?.ptr));
    try std.testing.expectEqual(@as(u32, 29), completions[0].recv_token);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x01, 'b' }, conn.raw_in.items);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.recycle_calls);

    backend.recycleRecv(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(u32, 29), backend.platform.last_recycled_token);

    try backend.submitRecv(82, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "b", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
    // The copied tail belongs to the adapter scratch pool, not the wrapped
    // platform whose token was already returned exactly once.
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in.items.len);
}

test "keyed-relay releases burst spill capacity around a partial next header" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try conn.raw_in.ensureTotalCapacityPrecise(backend.allocator, 4096);
    conn.raw_in.appendSliceAssumeCapacity(&.{ 0x82, 0x01, 'a', 0x82 });
    try backend.submitRecv(83, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].recv_bytes.?);
    try std.testing.expectEqualSlices(u8, &.{0x82}, conn.raw_in.items[conn.raw_in_head..]);
    try std.testing.expect(conn.raw_in.capacity <= keyed_relay.max_header_len + keyed_relay.max_control_payload);
    backend.recycleRecv(completions[0]);
}

test "keyed-relay header-only platform read waits for payload instead of reporting EOF" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.recv_payload = @constCast(&[_]u8{ 0x82, 0x01 });
    try backend.submitRecv(30, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(?u64, 30), conn.external_recv_ud);
    try std.testing.expectEqual(@as(u64, 1), conn.data_remaining);
    try std.testing.expect(conn.pending.recv);

    backend.platform.pending_recv = .{
        .user_data = backend.platform.armed_recv_ud.?,
        .result = 1,
        .recv_bytes = "x",
    };
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 30), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "x", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
}

test "keyed-relay reports wrapped transport EOF without turning it into failure" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitRecv(31, fd);
    backend.platform.pending_recv = .{
        .user_data = backend.platform.armed_recv_ud.?,
        .result = 0,
    };

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 31), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.shutdown_calls);
}

test "keyed-relay upgrade bounds only HTTP bytes and preserves coalesced frame residue" {
    var backend = try AdmissionBackend.initWithRelay(
        std.testing.allocator,
        8,
        1,
        8192,
        .{
            .url = "ws://127.0.0.1:1/relay",
            .entropy_seed = [_]u8{0x92} ** std.Random.DefaultCsprng.secret_seed_length,
            .send_staging_bytes = frame_cap,
        },
    );
    defer deinitAdmissionBackend(&backend);
    _ = try startUpgradeRelay(&backend);
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
    const payload_len = 5000;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try wire.appendSlice(std.testing.allocator, response);
    try wire.appendSlice(std.testing.allocator, &.{ 0x82, 126, 0x13, 0x88 });
    try wire.appendNTimes(std.testing.allocator, 0x5a, payload_len);
    // The coalesced read is larger than the completion adapter's 4 KiB HTTP
    // header cap, while the HTTP response itself remains well below it.
    try std.testing.expect(wire.items.len > 4096);

    try backend.platform.completeRecv(wire.items);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 7), completions[0].user_data);
    try std.testing.expectEqual(.open, conn.state);
    try std.testing.expectEqual(@as(usize, 0), conn.upgrade_buf.capacity);
    try std.testing.expectEqual(@as(usize, payload_len + 4), conn.raw_in.items.len - conn.raw_in_head);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0x13, 0x88 }, conn.raw_in.items[conn.raw_in_head..][0..4]);
}

test "keyed-relay upgrade retention has no geometric capacity above received bytes" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    _ = try startUpgradeRelay(&backend);
    const conn = backend.conns.get(1).?;
    const fragment = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n";

    try backend.platform.completeRecv(@constCast(fragment));

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(fragment.len, conn.upgrade_buf.items.len);
    try std.testing.expectEqual(fragment.len, conn.upgrade_buf.capacity);
}

test "keyed-relay repeated direct release and late close stay idempotent" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.closeFd(fd);
    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());

    try backend.submitClose(41, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 41), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
}

test "keyed-relay closing state refuses new recv and send seats" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    conn.state = .closing;

    try std.testing.expectError(error.ConnectionLost, backend.submitRecv(1, fd));
    try std.testing.expectError(error.ConnectionLost, backend.submitSend(2, fd, "x"));
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
}

test "keyed-relay partial application send gives way to one close frame" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(9, fd, "payload");
    backend.platform.pending_send.?.result = 1;
    try backend.submitClose(10, fd);

    var completions: [1]net.completion.Completion = undefined;
    // The synthetic close first cancels the caller's send seat.
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 9), completions[0].user_data);
    // Retiring the already-armed application frame discards its remainder and
    // submits exactly one WebSocket close before the wrapped descriptor close.
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);
    try std.testing.expect(backend.platform.pending_send != null);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.platform.pending_close != null);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 10), completions[0].user_data);
}

test "keyed-relay partial application send completes only after the frame drains" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitSend(44, fd, "payload");
    backend.platform.pending_send.?.result = 3;

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);
    try std.testing.expect(conn.ws_out_off > 0);
    try std.testing.expect(conn.ws_out_off < conn.ws_out.items.len);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 44), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 7), completions[0].result);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
    try std.testing.expectEqual(@as(usize, 0), conn.ws_out.items.len);
}

test "keyed-relay defers Loop shutdown until its WebSocket close drains" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.shutdownFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.shutdown_calls);
    try backend.submitClose(11, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.platform.shutdown_calls);
    try std.testing.expect(backend.platform.pending_close != null);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 11), completions[0].user_data);
}

test "keyed-relay releases a wrapped fd whose close completion fails" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    backend.platform.close_result = -1;

    try backend.submitClose(10, fd);
    var completions: [1]net.completion.Completion = undefined;
    // The close frame drains before the wrapped descriptor close is submitted.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 10), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay defers failed wrapped close release until receive retires" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitRecv(53, fd);
    backend.platform.close_result = -1;
    backend.platform.close_before_recv = true;
    try backend.submitClose(54, fd);

    var completions: [2]net.completion.Completion = undefined;
    // Synthetic close first retires the caller's receive seat while its wrapped
    // receive remains in flight.
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 53), completions[0].user_data);
    // The same fair poll also drains the WebSocket close send and submits the
    // wrapped close beside the still-armed receive.
    try std.testing.expect(conn.pending.recv);
    try std.testing.expectEqual(.in_flight, conn.close.platform);

    // Adversarial order: close failure first. The fd remains owned until the
    // receive CQE retires, so it cannot be reused beneath that operation.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(.failed, conn.close.platform);

    // Direct release may race this failed close completion. It must leave the
    // descriptor owned until the wrapped receive completion has retired.
    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(u64, 54), completions[0].user_data);
}

test "keyed-relay completion echoes a valid peer close before reporting EOF" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const payload = [_]u8{ 0x03, 0xe8, 'b', 'y', 'e' };
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x88, payload.len });
    try conn.raw_in.appendSlice(backend.allocator, &payload);

    try backend.submitRecv(44, fd);
    try std.testing.expect(conn.close.wire.hasReceived());
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expect(conn.pending.send);
    try std.testing.expectError(error.ConnectionLost, backend.submitSend(46, fd, "late"));
    try std.testing.expectEqual(@as(u8, 0x88), conn.ws_out.items[0]);
    try std.testing.expect(conn.ws_out.items[1] & 0x80 != 0);
    const mask = conn.ws_out.items[2..6];
    for (payload, 0..) |byte, i|
        try std.testing.expectEqual(byte, conn.ws_out.items[6 + i] ^ mask[i % 4]);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 44), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}

test "keyed-relay peer close takes priority over an application send deferred by pong" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    // The ping starts an internal pong send while the close remains buffered.
    // An application write arriving in that window must fail after the pong,
    // never appear on the wire ahead of the close response.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00, 0x88, 0x00 });
    try backend.submitRecv(47, fd);
    const late = "late";
    try backend.submitSend(48, fd, late);
    try std.testing.expectEqual(late.ptr, conn.external_send_remainder.ptr);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 48), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expect(conn.close.wire.hasReceived());
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);

    // The only send now in flight is the close response. Its completion then
    // retires the still-owned receive seat as EOF.
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 47), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}

test "keyed-relay local close releases an application send deferred by pong" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00 });
    try backend.submitRecv(49, fd);
    const retained = "retained-until-close";
    try backend.submitSend(50, fd, retained);
    try std.testing.expectEqual(retained.ptr, conn.external_send_remainder.ptr);

    try backend.submitClose(51, fd);
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
}

test "keyed-relay completion rejects an invalid peer close payload" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x88, 0x02, 0x03, 0xed });
    try backend.submitRecv(45, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 45), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
}

fn expectMaskedBinaryFrame(frame: []const u8, expected: []const u8) !void {
    try std.testing.expect(frame.len >= 6);
    try std.testing.expectEqual(@as(u8, 0x82), frame[0]);
    try std.testing.expect(frame[1] & 0x80 != 0);
    const len7 = frame[1] & 0x7f;
    const mask_at: usize = switch (len7) {
        126 => blk: {
            try std.testing.expect(frame.len >= 8);
            try std.testing.expectEqual(expected.len, std.mem.readInt(u16, frame[2..4], .big));
            break :blk 4;
        },
        127 => blk: {
            try std.testing.expect(frame.len >= 14);
            try std.testing.expectEqual(expected.len, std.mem.readInt(u64, frame[2..10], .big));
            break :blk 10;
        },
        else => blk: {
            try std.testing.expectEqual(expected.len, len7);
            break :blk 2;
        },
    };
    const payload_at = mask_at + 4;
    try std.testing.expectEqual(payload_at + expected.len, frame.len);
    const mask = frame[mask_at..payload_at];
    for (expected, frame[payload_at..], 0..) |want, got, i|
        try std.testing.expectEqual(want, got ^ mask[i % mask.len]);
}

test "keyed-relay completion chunks one borrowed write behind one completion" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes * 2 + 17]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    try backend.submitSend(47, fd, &payload);
    try std.testing.expectEqual(payload[chunk_bytes..].ptr, conn.external_send_remainder.ptr);
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[0..chunk_bytes]);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[chunk_bytes .. chunk_bytes * 2]);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[chunk_bytes * 2 ..]);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 47), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, payload.len), completions[0].result);
    try std.testing.expectEqual(@as(usize, 3), backend.platform.send_submits);
    try std.testing.expect(conn.ws_out.capacity <= frame_cap);
}

test "keyed-relay completion sends zero bytes without a WebSocket frame" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(48, fd, &.{});
    try std.testing.expectEqual(@as(usize, 0), backend.platform.send_submits);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 48), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}

test "keyed-relay completion answers a retained ping between send chunks" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 3]u8 = undefined;
    @memset(&payload, 0x5a);

    try backend.submitSend(49, fd, &payload);
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00 });
    var completions: [1]net.completion.Completion = undefined;

    // The first data chunk retires into a Pong, even though no application
    // receive seat exists to drive the ordinary receive projector.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u8, 0x8a), conn.ws_out.items[0]);
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);

    // Pong retirement admits the final byte-stream chunk; only that chunk's
    // retirement completes the original write.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[chunk_bytes..]);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 49), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, payload.len), completions[0].result);
}

test "keyed-relay completion honors a retained close between send chunks" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 1]u8 = undefined;
    @memset(&payload, 0x5b);

    try backend.submitSend(50, fd, &payload);
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x88, 0x00 });
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 50), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(@as(u8, 0x88), conn.ws_out.items[0]);
    try std.testing.expect(conn.close.wire.hasReceived());
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);
}

test "keyed-relay completion honors a close behind projected data between chunks" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 1]u8 = undefined;
    @memset(&payload, 0x5d);

    try backend.submitSend(52, fd, &payload);
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'x', 0x88, 0x00 });
    try backend.submitRecv(53, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 53), completions[0].user_data);
    try std.testing.expectEqualStrings("x", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
    try std.testing.expectEqual(@as(u64, 52), completions[1].user_data);
    try std.testing.expect(completions[1].result < 0);
    try std.testing.expectEqual(@as(u8, 0x88), conn.ws_out.items[0]);
}

test "keyed-relay completion makes a later chunk submit failure terminal" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 1]u8 = undefined;
    @memset(&payload, 0x5c);

    try backend.submitSend(51, fd, &payload);
    backend.platform.fail_send = true;
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 51), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(usize, 0), conn.ws_out.items.len);
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);
}

test "keyed-relay does not prefetch an open connection without a receive seat" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(51, fd, "payload");
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 51), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.recv_submits);
}

test "keyed-relay control send retains the receive seat through terminal failure" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    // A server ping immediately followed by binary application bytes. The
    // pong is an internal send, but its lifetime belongs to this receive: the
    // following binary frame must not retire the only Loop-visible seat first.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00, 0x82, 0x01, 'x' });
    try backend.submitRecv(61, fd);
    try std.testing.expectEqual(@as(?u64, 61), conn.external_recv_ud);
    try std.testing.expectEqual(@as(usize, 0), backend.ready.len());
    backend.platform.pending_send.?.result = -1;

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 61), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
}

test "keyed-relay app send during pong keeps the in-flight buffer stable" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00 });
    try backend.submitRecv(71, fd);
    try std.testing.expect(conn.pending.send);
    const in_flight_ptr = conn.ws_out.items.ptr;
    const in_flight_len = conn.ws_out.items.len;

    const payload = "payload";
    try backend.submitSend(72, fd, payload);
    try std.testing.expectEqual(in_flight_ptr, conn.ws_out.items.ptr);
    try std.testing.expectEqual(in_flight_len, conn.ws_out.items.len);
    try std.testing.expectEqual(payload.ptr, conn.external_send_remainder.ptr);

    var completions: [1]net.completion.Completion = undefined;
    // Pong completion frames and arms the deferred application send, but does
    // not report it complete before those bytes reach the platform.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(conn.pending.send);
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 72), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 7), completions[0].result);
}

test "keyed-relay completion path enforces WebSocket fragmentation order" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var completions: [1]net.completion.Completion = undefined;

    // A continuation has no authority without a preceding non-final binary
    // frame. Refuse it as a terminal transport fault, not CapTP payload.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x80, 0x01, 'x' });
    try backend.submitRecv(62, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 62), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
}

test "keyed-relay completion path streams a valid fragmented binary message" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var completions: [1]net.completion.Completion = undefined;

    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x02, 0x01, 'a', 0x80, 0x01, 'b' });
    try backend.submitRecv(63, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);

    try backend.submitRecv(64, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "b", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
    try std.testing.expect(!conn.fragmented);
}

test "keyed-relay completion receive advances a cursor without shifting payload" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var wire: [132]u8 = undefined;
    const header = [_]u8{ 0x82, 126, 0, 128 };
    @memcpy(wire[0..4], &header);
    @memset(wire[4..], 0x5a);
    try conn.raw_in.ensureTotalCapacityPrecise(backend.allocator, wire.len);
    conn.raw_in.appendSliceAssumeCapacity(&wire);

    try backend.submitRecv(65, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 64), completions[0].recv_bytes.?.len);
    try std.testing.expectEqual(@as(usize, 132), conn.raw_in.items.len);
    try std.testing.expectEqual(@as(usize, 68), conn.raw_in_head);
    backend.recycleRecv(completions[0]);

    try backend.submitRecv(66, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 64), completions[0].recv_bytes.?.len);
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in.items.len);
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in_head);
    backend.recycleRecv(completions[0]);
}

test "keyed-relay retries wrapped-platform recv-buffer starvation" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(71, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(.open, conn.state);
    try std.testing.expectEqual(@as(?u64, 71), conn.external_recv_ud);
    try std.testing.expect(backend.recv_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 1), backend.recv_retries.head);

    backend.platform.emit_recv_no_buffer = false;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_submits);
    try std.testing.expect(backend.recv_retries.contains(conn));

    // Polling cannot manufacture a platform buffer. Returning one is the
    // progress edge that retries every starved receive exactly once.
    backend.recycleRecv(.{ .user_data = 0, .result = 0, .recv_token = 42 });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 2), backend.platform.recv_submits);
    try std.testing.expect(!backend.recv_retries.contains(conn));
    try std.testing.expect(conn.pending.recv);
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.tail);
}

test "keyed-relay canceled receive is not rearmed after buffer starvation" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(72, fd);
    try backend.submitCancel(73, 72, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expect(!backend.recv_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);

    backend.platform.emit_recv_no_buffer = false;
    backend.recycleRecv(.{ .user_data = 0, .result = 0, .recv_token = 42 });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_submits);
    try std.testing.expect(!conn.pending.recv);
}

test "keyed-relay canceled receive preserves a late platform payload" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var wire = [_]u8{ 0x82, 0x01, 'a' };
    backend.platform.recv_payload = &wire;

    try backend.submitRecv(76, fd);
    try backend.submitCancel(77, 76, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, &wire, conn.raw_in.items);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);

    try backend.submitRecv(78, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 78), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "a", completions[0].recv_bytes.?);
    backend.recycleRecv(completions[0]);
}

test "keyed-relay cancellation removes an already queued receive retry" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(74, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.recv_retries.contains(conn));

    try backend.submitCancel(75, 74, fd);
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expect(!backend.recv_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);

    backend.platform.emit_recv_no_buffer = false;
    backend.recycleRecv(.{ .user_data = 0, .result = 0, .recv_token = 42 });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_submits);
    try std.testing.expect(!conn.pending.recv);
}

test "keyed-relay recv starvation after wrapped close still completes close" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(72, fd);
    backend.platform.close_before_recv = true;
    try backend.submitClose(73, fd);

    var completions: [2]net.completion.Completion = undefined;
    // The caller's receive seat is canceled while its wrapped receive remains
    // in flight; the close frame then drains and submits the wrapped close.
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 72), completions[0].user_data);
    try std.testing.expect(conn.pending.recv);
    try std.testing.expectEqual(.in_flight, conn.close.platform);

    // Adversarial order: descriptor close completes before the no-buffer CQE.
    // The latter retires the final operation and must take the common terminal
    // path rather than enqueue a read that a closing connection cannot use.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(.closed, conn.close.platform);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 73), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);
}

// --- The loopback scenario -------------------------------------------------

fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(keyed_relay.transport_name, designator);
}

fn holdParkedRegistration(
    io: Io,
    server: *ip.Server,
    pong_seen: *std.atomic.Value(bool),
) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
    try ws_relay.writeServerFrame(&leg, .ping, "ready");
    var payload: [16]u8 = undefined;
    const pong = try ws_relay.readClientFrame(&leg, &payload);
    try std.testing.expectEqual(keyed_relay.Opcode.pong, pong.opcode);
    try std.testing.expectEqualStrings("ready", pong.payload);
    pong_seen.store(true, .release);
    // Listener destruction is abortive and must not perform a network flush.
    // The peer observes EOF rather than a destructor-generated close frame.
    try std.testing.expectError(error.EndOfStream, ws_relay.readClientFrame(&leg, &payload));
}

fn waitOnRegisteredListener(listener: net.netlayer.Listener, out_err: *?anyerror) void {
    _ = listener.waitAcceptable(-1) catch |err| {
        out_err.* = err;
        return;
    };
    out_err.* = error.UnexpectedReadiness;
}

fn stallInitialRegistration(
    io: Io,
    server: *ip.Server,
    connected: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),
) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    connected.store(true, .release);
    // Accept TCP but never answer the HTTP upgrade. The listener must already
    // have returned, and its close must cancel this task without cooperation.
    try wait.untilFlag(io, wait.default_deadline_ms, release);
}

test "keyed-relay listen owns a stalled initial registration asynchronously" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed([_]u8{0x6c} ** crypto.SEED_BYTES);
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    defer resident.deinit();

    var connected = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(stallInitialRegistration, .{ io, &server, &connected, &release });
    defer {
        release.store(true, .release);
        relay.await(io) catch {};
    }

    const listener = try resident.netlayer().listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    try wait.untilFlag(io, wait.default_deadline_ms, &connected);
    try std.testing.expect(!try listener.waitReady(20));
    try std.testing.expectError(error.BindFailed, listener.localLocator(allocator));
    try std.testing.expect(!try listener.waitAcceptable(20));
    listener.close();
}

test "keyed-relay listener close wakes and joins a parked readiness wait" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed([_]u8{0x6d} ** crypto.SEED_BYTES);
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    defer resident.deinit();

    var pong_seen = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(holdParkedRegistration, .{ io, &server, &pong_seen });
    const listener = try resident.netlayer().listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    try std.testing.expect(try listener.waitReady(1000));
    const expected_designator = identity.publicKey().toDesignator();
    const locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, locator);
    try std.testing.expectEqualStrings(&expected_designator, locator.designator);
    var wait_err: ?anyerror = null;
    var waiter = try io.concurrent(waitOnRegisteredListener, .{ listener, &wait_err });

    try wait.untilFlag(io, wait.default_deadline_ms, &pong_seen);
    listener.close();
    waiter.await(io);
    try std.testing.expectEqual(error.ConnectionLost, wait_err.?);
    try relay.await(io);
}

fn serveOneRegistrationThenStallReplacement(
    io: Io,
    server: *ip.Server,
    replacement_seen: *std.atomic.Value(bool),
    drop_replacement: *std.atomic.Value(bool),
    dropped_replacement: *std.atomic.Value(bool),
    recovered_seen: *std.atomic.Value(bool),
    send_recovered: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),
) !void {
    var first: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    first.wire();
    defer first.close();
    try ws_relay.serveUpgrade(&first);
    try ws_relay.writeServerFrame(&first, .binary, "x");

    const replacement = try server.accept(io);
    var replacement_live = true;
    defer if (replacement_live) replacement.close(io);
    replacement_seen.store(true, .release);
    // Deliberately never answer the second HTTP upgrade. Closing this leg
    // forces the listener through its retry path rather than leaving an
    // advertised but unreachable key behind.
    try wait.untilFlag(io, wait.default_deadline_ms, drop_replacement);
    replacement.close(io);
    replacement_live = false;
    dropped_replacement.store(true, .release);

    var recovered: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    recovered.wire();
    defer recovered.close();
    try ws_relay.serveUpgrade(&recovered);
    recovered_seen.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, send_recovered);
    try ws_relay.writeServerFrame(&recovered, .binary, "recovered");
    try wait.untilFlag(io, wait.default_deadline_ms, release);
}

test "keyed-relay listener withdraws and recovers a stalled replacement" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/register", .{port});
    const identity = crypto.SecretKey.fromSeed([_]u8{0x6e} ** crypto.SEED_BYTES);
    var resident = try keyed_relay.Resident.initRegistered(allocator, io, url, url, identity.publicKey());
    var resident_live = true;
    defer if (resident_live) resident.deinit();

    var replacement_seen = std.atomic.Value(bool).init(false);
    var drop_replacement = std.atomic.Value(bool).init(false);
    var dropped_replacement = std.atomic.Value(bool).init(false);
    var recovered_seen = std.atomic.Value(bool).init(false);
    var send_recovered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(serveOneRegistrationThenStallReplacement, .{
        io,
        &server,
        &replacement_seen,
        &drop_replacement,
        &dropped_replacement,
        &recovered_seen,
        &send_recovered,
        &release,
    });
    defer {
        release.store(true, .release);
        relay.await(io) catch {};
    }

    var listener_arena = std.heap.ArenaAllocator.init(allocator);
    var listener_arena_live = true;
    defer if (listener_arena_live) listener_arena.deinit();
    const listener = try resident.netlayer().listen(listener_arena.allocator(), .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    var listener_live = true;
    defer if (listener_live) listener.close();
    try std.testing.expect(try listener.waitAcceptable(1000));
    // The relay spent the first registration when it paired this ready socket.
    // Until accept starts a replacement, the listener must not advertise a
    // cold-dial route that no longer exists.
    try std.testing.expect(!try listener.waitReady(0));
    // A positive wait has the same observation-only contract while the sole
    // accepted slot is occupied. It must not start a second registration that
    // could overwrite this socket before accept consumes it.
    try std.testing.expect(!try listener.waitReady(20));
    try std.testing.expect(!replacement_seen.load(.acquire));
    try std.testing.expectError(error.BindFailed, listener.localLocator(allocator));
    // The listener's replacement leg is its own lifetime. Destroying the
    // factory before accept must not leave that task borrowing URL slices.
    resident.deinit();
    resident_live = false;
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var conn = try listener.accept(&peer, .{ .read = &read_buf, .write = &write_buf });
    defer conn.deinit();

    try wait.untilFlag(io, wait.default_deadline_ms, &replacement_seen);
    try std.testing.expectError(error.BindFailed, listener.localLocator(allocator));
    try std.testing.expect(
        !try listener.waitAcceptable(20),
    );

    drop_replacement.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, &dropped_replacement);
    try std.testing.expectError(error.BindFailed, listener.localLocator(allocator));
    try std.testing.expect(try listener.waitReady(1000));
    try wait.untilFlag(io, wait.default_deadline_ms, &recovered_seen);
    const recovered_locator = try listener.localLocator(allocator);
    model.freePeerLocator(allocator, recovered_locator);
    send_recovered.store(true, .release);
    try std.testing.expect(try listener.waitAcceptable(1000));

    release.store(true, .release);
    listener.close();
    listener_live = false;

    // Accept transfers the pinned stream to the peer. Releasing every byte of
    // listener storage must leave the connection's interfaces and close handle
    // valid until the peer-owned connection is released.
    listener_arena.deinit();
    listener_arena_live = false;
    try std.testing.expect(conn.socketHandle() != null);
}

/// The registered peer: accept through the relay's ping in the parked
/// registration, then serve the bootstrap fetch. Calling `accept` directly is
/// intentional: the resident listener owns the blocking wait just like TCP.
/// The listener's owned registration task is already running before this
/// waiter starts; the relay fixture accepts that registration before the dial.
fn serveRegistered(
    listener: net.netlayer.Listener,
    identity: crypto.PeerKey,
    allocator: std.mem.Allocator,
) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, .{ .read = read_buf, .write = write_buf });
    defer conn.deinit();

    const hex = identity.toDesignator();
    try peer.sendCopying(startSession(hex[0..]));

    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

test "keyed-relay loopback: register, ping in the park, cold dial, fetch round-trip" {
    const allocator = std.testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    const identity = crypto.SecretKey.fromSeed([_]u8{0x6e} ** crypto.SEED_BYTES);

    var registered = try keyed_relay.Resident.initRegistered(
        allocator,
        io,
        relay_url,
        register_url,
        identity.publicKey(),
    );
    defer registered.deinit();
    var dialer = try keyed_relay.Resident.init(allocator, io, relay_url);
    defer dialer.deinit();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &server, allocator });

    // `listen` schedules registration without performing network I/O itself.
    // The relay fixture accepts that leg first and pings it before accepting
    // the rendezvous leg, proving the parked task is live before data arrives.
    const registered_nl = registered.netlayer();
    const listener = try registered_nl.listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    defer listener.close();

    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });

    // Registration is background-owned, so nothing else orders the cold dial
    // behind it: under CPU load the dial leg can win the race to the relay's
    // accept and land where the fixture expects the registration leg. The
    // readiness edge the listener contract carries for exactly this
    // (`waitReady`) is the sequencing, not a sleep.
    try std.testing.expect(try listener.waitReady(10_000));

    // The dialing peer: cold dial the registered key through the relay.
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const designator = identity.publicKey().toDesignator();
    const locator: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyMap(),
    };
    const client_result = blk: {
        const nl = dialer.netlayer();
        var conn = nl.dial(&peer, locator, .{ .read = read_buf, .write = write_buf }) catch |err| break :blk err;
        defer conn.deinit();
        fetch_pump.handshakeToOpen(&peer, &conn, startSession("client")) catch |err| break :blk err;
        const reference = fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat") catch |err| break :blk err;
        model.freeReference(allocator, reference);
        break :blk {};
    };

    const serve_result = serve_future.await(io);
    const relay_result = relay_future.await(io);
    try client_result;
    try serve_result;
    try relay_result;
}

test "keyed-relay routes a cold dial through the target's other relay" {
    const allocator = std.testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Keep the configured relay distinct and unavailable. A successful dial
    // therefore proves the locator hint selected the target's relay rather
    // than merely using the resident default.
    const unused_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var unused_server = try ip.IpAddress.listen(&unused_addr, io, .{ .reuse_address = true });
    const unused_port = unused_server.socket.address.getPort();
    unused_server.deinit(io);

    const target_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var target_server = try ip.IpAddress.listen(&target_addr, io, .{ .reuse_address = true });
    defer target_server.deinit(io);
    const target_port = target_server.socket.address.getPort();

    var configured_url_buf: [64]u8 = undefined;
    const configured_url = try std.fmt.bufPrint(
        &configured_url_buf,
        "ws://127.0.0.1:{d}/relay",
        .{unused_port},
    );
    var target_relay_url_buf: [64]u8 = undefined;
    const target_relay_url = try std.fmt.bufPrint(
        &target_relay_url_buf,
        "ws://127.0.0.1:{d}/relay",
        .{target_port},
    );
    var target_register_url_buf: [64]u8 = undefined;
    const target_register_url = try std.fmt.bufPrint(
        &target_register_url_buf,
        "ws://127.0.0.1:{d}/register",
        .{target_port},
    );

    const identity = crypto.SecretKey.fromSeed([_]u8{0x7a} ** crypto.SEED_BYTES);
    var registered = try keyed_relay.Resident.initRegistered(
        allocator,
        io,
        target_relay_url,
        target_register_url,
        identity.publicKey(),
    );
    defer registered.deinit();
    var dialer = try keyed_relay.Resident.init(allocator, io, configured_url);
    defer dialer.deinit();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &target_server, allocator });

    const listener = try registered.netlayer().listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    defer listener.close();
    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });
    try std.testing.expect(try listener.waitReady(10_000));

    const advertised = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, advertised);
    try std.testing.expectEqualStrings(
        keyed_relay.rendezvous_relay_hint,
        advertised.hints.entries[0].name,
    );
    try std.testing.expectEqualStrings(
        target_relay_url,
        advertised.hints.entries[0].value.string,
    );

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const locator = advertised;
    const client_result = blk: {
        var conn = dialer.netlayer().dial(&peer, locator, .{ .read = read_buf, .write = write_buf }) catch |err|
            break :blk err;
        defer conn.deinit();
        fetch_pump.handshakeToOpen(&peer, &conn, startSession("client")) catch |err|
            break :blk err;
        break :blk {};
    };

    const serve_result = serve_future.await(io);
    const relay_result = relay_future.await(io);
    try client_result;
    try serve_result;
    try relay_result;
}

test "keyed-relay refuses malformed, typed, duplicate, and oversized relay hints" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var resident = try keyed_relay.Resident.init(allocator, threaded.io(), "ws://127.0.0.1:1/relay");
    defer resident.deinit();

    const identity = crypto.SecretKey.fromSeed([_]u8{0x7b} ** crypto.SEED_BYTES);
    const designator = identity.publicKey().toDesignator();

    // A listener cannot truthfully advertise the dial URL when registration
    // is on a different relay authority.
    try std.testing.expectError(
        error.InvalidRelayUrl,
        keyed_relay.Resident.initRegistered(
            allocator,
            threaded.io(),
            "ws://127.0.0.1:1/relay",
            "ws://127.0.0.1:2/register",
            identity.publicKey(),
        ),
    );

    const invalid_values = [_]model.HintValue{
        .{ .string = "http://127.0.0.1:1/relay" },
        .{ .string = "ws://127.0.0.1:1/relay#fragment" },
        .{ .bytes = "ws://127.0.0.1:1/relay" },
    };
    for (invalid_values) |value| {
        const locator: model.PeerLocator = .{
            .transport = keyed_relay.transport_name,
            .designator = designator[0..],
            .hints = .{ .entries = &.{.{
                .name = keyed_relay.rendezvous_relay_hint,
                .value = value,
            }} },
        };
        try std.testing.expectError(error.InvalidAddress, resident.dialRaw(locator));
        try std.testing.expectError(error.InvalidAddress, keyed_relay.DialResolver.resolve(locator));
    }

    var oversized: [keyed_relay.max_rendezvous_relay_hint_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    const oversized_locator: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = .{ .entries = &.{.{
            .name = keyed_relay.rendezvous_relay_hint,
            .value = .{ .string = &oversized },
        }} },
    };
    try std.testing.expectError(error.InvalidAddress, resident.dialRaw(oversized_locator));
    try std.testing.expectError(error.InvalidAddress, keyed_relay.DialResolver.resolve(oversized_locator));

    const duplicate_locator: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = .{ .entries = &.{
            .{ .name = keyed_relay.rendezvous_relay_hint, .value = .{ .string = "ws://127.0.0.1:1/relay" } },
            .{ .name = keyed_relay.rendezvous_relay_hint, .value = .{ .string = "ws://127.0.0.1:1/relay" } },
        } },
    };
    try std.testing.expectError(error.InvalidAddress, resident.dialRaw(duplicate_locator));
    try std.testing.expectError(error.InvalidAddress, keyed_relay.DialResolver.resolve(duplicate_locator));
}

const LoopClientCtx = struct {
    allocator: std.mem.Allocator,
    done: *std.atomic.Value(bool),
    fetch_sent: bool = false,
    answer_position: model.AnswerPosition = .from(0),
    resolver_export: ?model.ExportPosition = null,

    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        const self: *LoopClientCtx = @ptrCast(@alignCast(conn_ctx.?));
        if (!self.fetch_sent and peer.sessionIsOpen()) {
            const prepared = try engine.fetch.prepareFetchSwissnum(self.allocator, &peer.session_state, "thermostat");
            self.answer_position = prepared.answer_position;
            self.resolver_export = prepared.resolver_export;
            self.fetch_sent = true;
            try peer.send(prepared.message);
            return;
        }
        if (!self.fetch_sent) return;

        const matched = try fetch_pump.matchFetchEvent(
            self.allocator,
            self.resolver_export,
            self.answer_position,
            event,
        );
        if (matched) |reference| {
            model.freeReference(self.allocator, reference);
            self.done.store(true, .release);
        }
    }
};

fn makeLoopClientPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = stubNegotiatingPeer(allocator);
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    try peer.sendCopying(startSession("client"));
    return peer;
}

fn makeLoopClientCtx(ctx: ?*anyopaque, _: *engine.Peer, _: usize) anyerror!?*anyopaque {
    return ctx;
}

const FailedDialJournal = struct {
    closes: usize = 0,
    opened: bool = true,

    fn onClose(
        ctx: ?*anyopaque,
        _: usize,
        conn_ctx: ?*anyopaque,
        opened: bool,
        _: net.completion.CloseReason,
    ) void {
        const self: *FailedDialJournal = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(conn_ctx == null);
        self.closes += 1;
        self.opened = opened;
    }
};

test "keyed-relay completion loop reclaims a wrapped connect failure unopened" {
    const Loop = net.completion.Loop(AdmissionBackend, keyed_relay.DialResolver);
    var journal: FailedDialJournal = .{};
    const backend = try admissionBackend(std.testing.allocator);
    var loop = try Loop.initWithBackend(
        std.testing.allocator,
        backend,
        makeLoopClientPeer,
        @ptrCast(&journal),
        .{
            .max_conns = 1,
            .on_close = FailedDialJournal.onClose,
        },
    );
    defer loop.deinit();

    const designator = [_]u8{'a'} ** 64;
    _ = try loop.dialLocator(.{
        .transport = keyed_relay.transport_name,
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    loop.backend.platform.pending_connect.?.result = -1;

    try loop.run(.{ .after_closed = 1 });
    try loop.closeAndDrain();

    try std.testing.expectEqual(@as(usize, 1), journal.closes);
    try std.testing.expect(!journal.opened);
    try std.testing.expectEqual(@as(usize, 0), loop.backend.conns.count());
    try std.testing.expectEqual(@as(usize, 1), loop.backend.platform.close_submits);
    try std.testing.expectEqual(@as(usize, 0), loop.backend.platform.close_calls);
    try std.testing.expect(loop.backend.platform.pending_close == null);
}

fn runKeyedRelayLoopUntil(
    loop: *net.KeyedRelayLoop,
    done: *const std.atomic.Value(bool),
    out_err: *?anyerror,
) void {
    loop.runUntil(done, 5_000) catch |err| {
        out_err.* = err;
    };
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
}

test "keyed-relay completion loop: evented cold dial fetches through relay" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    const identity = crypto.SecretKey.fromSeed([_]u8{0x71} ** crypto.SEED_BYTES);

    var registered = try keyed_relay.Resident.initRegistered(
        allocator,
        io,
        relay_url,
        register_url,
        identity.publicKey(),
    );
    defer registered.deinit();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &server, allocator });

    const registered_nl = registered.netlayer();
    const listener = try registered_nl.listen(allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    defer listener.close();

    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });

    // The same sequencing the blocking test needs: the fixture accepts the
    // registration leg first, so the cold dial waits for the background
    // registration through the listener's readiness edge.
    try std.testing.expect(try listener.waitReady(10_000));

    var done = std.atomic.Value(bool).init(false);
    var client_ctx = LoopClientCtx{ .allocator = allocator, .done = &done };

    var relay_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&relay_seed);
    const backend = try net.KeyedRelayBackend.initWithRelay(allocator, 64, 16, frame_cap, .{
        .url = relay_url,
        .entropy_seed = relay_seed,
        // Force the live CapTP conversation through multiple complete binary
        // messages; the relay and both byte-stream readers must erase those
        // WebSocket boundaries.
        .send_staging_bytes = keyed_relay.max_header_len + keyed_relay.max_control_payload,
    });
    var loop = try net.KeyedRelayLoop.initWithBackend(allocator, backend, makeLoopClientPeer, @ptrCast(&client_ctx), .{
        .max_conns = 4,
        .make_conn_ctx = makeLoopClientCtx,
        .serve = LoopClientCtx.serve,
        .free_conn_ctx = null,
    });
    defer loop.deinit();

    const designator = identity.publicKey().toDesignator();
    _ = try loop.dialLocator(.{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    });

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runKeyedRelayLoopUntil, .{ &loop, &done, &loop_err });
    loop_future.await(io);
    const serve_result = serve_future.await(io);
    const relay_result = relay_future.await(io);

    if (loop_err) |err| return err;
    try serve_result;
    try relay_result;
    try std.testing.expect(done.load(.acquire));
}

test "keyed-relay dial refuses a non-key designator and a listen without registration config" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try keyed_relay.Resident.init(allocator, io, "ws://127.0.0.1:1/relay");
    defer resident.deinit();
    const nl = resident.netlayer();

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    // A non-key designator refuses before any I/O.
    const bad: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = "not-a-key",
        .hints = model.Hints.emptyMap(),
    };
    try std.testing.expectError(
        error.InvalidAddress,
        nl.dial(&peer, bad, .{ .read = &read_buf, .write = &write_buf }),
    );
    var backend = try admissionBackend(allocator);
    defer deinitAdmissionBackend(&backend);
    try std.testing.expectError(
        error.InvalidAddress,
        backend.startDial(1, .{ .keyed_relay = .{ .designator = "not-a-key\r\nInjected: yes", .relay = null } }),
    );

    // A dial-only resident (no register URL, no identity) refuses listen.
    try std.testing.expectError(
        error.InvalidAddress,
        nl.listen(allocator, .{ .designator = "" }),
    );
}
