const std = @import("std");
const c = @import("c_abi_shared");
const foundation = @import("foundation");
const net = @import("net");
const webrtc = @import("webrtc");
const webrtc_archive = @import("c_abi_net_transport_webrtc");

/// One open DataChannel's adapter row: the 48-byte sidecar peer beside the
/// hinted try-I/O seats, hints, and terminal cause every multiplexed sidecar
/// backend shares. No embedded list header, so the number holds in every
/// build mode.
const webrtc_connection_state_bytes: usize = 104;

test "supported WebRTC type surfaces and footprints stay exact" {
    const root_names = .{ "transport_name", "max_packet_bytes", "max_signal_bytes", "max_ice_candidate_bytes", "max_ice_servers", "max_ice_urls_per_server", "max_ice_url_bytes", "max_ice_credential_bytes", "max_pending_ice_candidates", "pending_ice_candidate_queue_bytes", "data_channel_queue_bytes", "sctp_receive_buffer_bytes", "designator_scheme", "designator_len", "locator", "ev_open", "ev_candidate", "ev_readable", "ev_writable", "ev_closed", "ReadyEvent", "PeerId", "StringView", "IceServerConfig", "SignalError", "Peer", "Resident", "DialResolver", "SignalingAuthority", "Backend" };
    try std.testing.expectEqual(root_names.len, @typeInfo(webrtc).@"struct".decl_names.len);
    inline for (root_names) |name| try std.testing.expect(@hasDecl(webrtc, name));

    try std.testing.expectEqual(@as(usize, 48), @sizeOf(webrtc.Peer));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(webrtc.Peer));
    try std.testing.expectEqual(webrtc_connection_state_bytes, webrtc.Backend.connection_state_bytes);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(webrtc.Resident));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(webrtc.Resident));
    try std.testing.expectEqual(@as(usize, 16 * 1024), webrtc.max_signal_bytes);
    try std.testing.expectEqual(webrtc.max_signal_bytes, webrtc.max_ice_candidate_bytes);
    try std.testing.expectEqual(@as(usize, 16), webrtc.max_ice_servers);
    try std.testing.expectEqual(@as(usize, 16), webrtc.max_ice_urls_per_server);
    try std.testing.expectEqual(@as(usize, 2 * 1024), webrtc.max_ice_url_bytes);
    try std.testing.expectEqual(@as(usize, 4 * 1024), webrtc.max_ice_credential_bytes);
    try std.testing.expectEqual(@as(usize, 256), webrtc.max_pending_ice_candidates);
    try std.testing.expectEqual(@as(usize, 64 * 1024), webrtc.pending_ice_candidate_queue_bytes);
    try std.testing.expectEqual(@as(usize, 1 * 1024 * 1024), webrtc.data_channel_queue_bytes);
    try std.testing.expectEqual(webrtc.data_channel_queue_bytes, webrtc.sctp_receive_buffer_bytes);

    const peer_names = .{ "InitError", "id", "authorizeRemote", "close", "deinit", "createOffer", "createAnswer", "setRemoteOffer", "setRemoteAnswer", "addRemoteCandidate", "nextLocalCandidate", "OpenError", "checkOpen", "TryPacketError", "tryReceivePacket", "trySendPacket" };
    try std.testing.expectEqual(peer_names.len, @typeInfo(webrtc.Peer).@"struct".decl_names.len);
    inline for (peer_names) |name| try std.testing.expect(@hasDecl(webrtc.Peer, name));

    const resident_names = .{ "InitError", "Config", "init", "deinit", "newPeer", "readinessFd", "drainReady", "driverReadinessFd", "drainDriverReady", "pollReady" };
    try std.testing.expectEqual(resident_names.len, @typeInfo(webrtc.Resident).@"struct".decl_names.len);
    inline for (resident_names) |name| try std.testing.expect(@hasDecl(webrtc.Resident, name));

    const backend_names = .{ "Fd", "ConnectTarget", "ListenerAddress", "listen_fd", "connection_state_bytes", "initBound", "deinit", "openListener", "listenerAddress", "listenerPort", "startDial", "adoptAnswerer", "provideAnswer", "provideRemoteCandidate", "wake", "applyKeepalive", "wireFraming", "closeFd", "shutdownFd", "recycleBorrowed", "verifiedChannelKey", "submitAccept", "submitRecv", "submitSend", "submitCancel", "submitClose", "poll" };
    try std.testing.expectEqual(backend_names.len, @typeInfo(webrtc.Backend).@"struct".decl_names.len);
    inline for (backend_names) |name| try std.testing.expect(@hasDecl(webrtc.Backend, name));

    comptime {
        expectSignature(@TypeOf(webrtc.Backend.initBound), &.{ std.mem.Allocator, *webrtc.Resident, webrtc.SignalingAuthority, u16, u32 }, webrtc.Backend);
        expectSignature(@TypeOf(webrtc.Backend.startDial), &.{ *webrtc.Backend, u64, webrtc.Backend.ConnectTarget }, webrtc.Backend.Fd);
        expectSignature(@TypeOf(webrtc.Backend.adoptAnswerer), &.{ *webrtc.Backend, webrtc.Peer }, webrtc.Backend.Fd);
        expectSignature(@TypeOf(webrtc.Backend.provideAnswer), &.{ *webrtc.Backend, webrtc.Backend.Fd, []const u8 }, void);
        expectSignature(@TypeOf(webrtc.Backend.provideRemoteCandidate), &.{ *webrtc.Backend, webrtc.Backend.Fd, []const u8 }, void);
        expectSignature(@TypeOf(webrtc.Backend.poll), &.{ *webrtc.Backend, []net.completion.Completion, i32 }, usize);
    }

    // The `Backend` footprint is stated under runtime safety, where each
    // embedded `std.ArrayList` header carries std's one-word
    // `pointer_stability` lock: 48 of these bytes, one fixed charge per loop.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 760), @sizeOf(webrtc.Backend));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(webrtc.Backend));
}

fn expectSignature(comptime Function: type, comptime Params: []const type, comptime Payload: type) void {
    const info = @typeInfo(Function).@"fn";
    if (info.param_types.len != Params.len) @compileError("WebRTC supported method arity drifted");
    inline for (Params, 0..) |expected, index| {
        if (info.param_types[index].? != expected) @compileError("WebRTC supported parameter type drifted");
    }
    const return_type = info.return_type.?;
    const payload = switch (@typeInfo(return_type)) {
        .error_union => |error_union| error_union.payload,
        else => return_type,
    };
    if (payload != Payload) @compileError("WebRTC supported return shape drifted");
}

var freed_peers: usize = 0;
var candidate_bytes_to_emit: usize = 0;
var candidate_reads: usize = 0;
var candidate_sent_bytes: usize = 0;
var create_offer_result: i32 = -2;
var create_answer_result: i32 = -2;
var create_signal_len: usize = 0;
var set_remote_calls: usize = 0;
var add_remote_candidate_calls: usize = 0;
var open_result: i32 = -2;
var open_checks: usize = 0;
var receive_result: isize = -2;

export fn glowcap_webrtc_sidecar_endpoint_new(_: *const anyopaque) callconv(.c) ?*anyopaque {
    return @ptrFromInt(1);
}
export fn glowcap_webrtc_sidecar_endpoint_readiness_fd(_: *const anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_webrtc_sidecar_endpoint_drain_ready(_: *const anyopaque, _: [*]webrtc.ReadyEvent, _: usize) callconv(.c) isize {
    return 0;
}
export fn glowcap_webrtc_sidecar_endpoint_driver_readiness_fd(_: *const anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_webrtc_sidecar_endpoint_drain_driver_ready(_: *const anyopaque, _: [*]webrtc.ReadyEvent, _: usize) callconv(.c) isize {
    return 0;
}
export fn glowcap_webrtc_sidecar_endpoint_free(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_webrtc_sidecar_peer_new(_: *anyopaque, _: i32) callconv(.c) ?*anyopaque {
    return @ptrFromInt(2);
}
export fn glowcap_webrtc_sidecar_peer_id(peer: *const anyopaque) callconv(.c) usize {
    return @intFromPtr(peer);
}
export fn glowcap_webrtc_sidecar_peer_create_offer(_: *anyopaque, _: [*]u8, _: usize, out_len: *usize) callconv(.c) i32 {
    out_len.* = create_signal_len;
    return create_offer_result;
}
export fn glowcap_webrtc_sidecar_peer_create_answer(_: *anyopaque, _: [*]u8, _: usize, out_len: *usize) callconv(.c) i32 {
    out_len.* = create_signal_len;
    return create_answer_result;
}
export fn glowcap_webrtc_sidecar_peer_add_remote_candidate(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) i32 {
    add_remote_candidate_calls += 1;
    return -1;
}
export fn glowcap_webrtc_sidecar_peer_set_remote(_: *anyopaque, _: [*]const u8, _: usize, _: i32) callconv(.c) i32 {
    set_remote_calls += 1;
    return -1;
}
export fn glowcap_webrtc_sidecar_peer_next_local_candidate(_: *anyopaque, out: [*]u8, cap: usize, out_len: *usize) callconv(.c) i32 {
    candidate_reads += 1;
    if (candidate_bytes_to_emit != 0) {
        out_len.* = candidate_bytes_to_emit;
        if (candidate_bytes_to_emit > cap) return -3;
        @memset(out[0..candidate_bytes_to_emit], 'c');
        candidate_bytes_to_emit = 0;
        return 0;
    }
    return -2;
}
export fn glowcap_webrtc_sidecar_peer_is_open(_: *const anyopaque) callconv(.c) i32 {
    open_checks += 1;
    return open_result;
}
export fn glowcap_webrtc_sidecar_conn_try_receive_packet(_: *anyopaque, _: [*]u8, _: usize) callconv(.c) isize {
    return receive_result;
}
export fn glowcap_webrtc_sidecar_conn_try_send_packet(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) isize {
    return -2;
}
export fn glowcap_webrtc_sidecar_conn_close(_: *anyopaque) callconv(.c) void {}
export fn glowcap_webrtc_sidecar_peer_free(_: *anyopaque) callconv(.c) void {
    freed_peers += 1;
}

fn ignoreOffer(_: *anyopaque, _: i32, _: []const u8, _: []const u8) anyerror!void {}
fn ignoreCandidate(_: *anyopaque, _: i32, _: []const u8) anyerror!void {}
fn observeCandidate(_: *anyopaque, _: i32, candidate: []const u8) anyerror!void {
    candidate_sent_bytes = candidate.len;
}

fn webrtcProviderTable(provider: c.GlowcapTransportProvider) *const c.GlowcapMultiplexedTransport {
    for (provider.entries.?[0..provider.entry_count]) |entry| {
        const profile = entry.profile.?;
        const name = profile.transport_name.?[0..profile.transport_name_len];
        if (std.mem.eql(u8, name, webrtc.transport_name))
            return @ptrCast(@alignCast(entry.implementation.?));
    }
    unreachable;
}

test "signaling inputs are bounded before entering the sidecar" {
    set_remote_calls = 0;
    add_remote_candidate_calls = 0;
    var peer: webrtc.Peer = .{ .peer = @ptrFromInt(104) };
    var oversized: [webrtc.max_signal_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.SignalTooLarge, peer.setRemoteOffer(&oversized));
    try std.testing.expectError(error.SignalTooLarge, peer.addRemoteCandidate(&oversized));
    try std.testing.expectEqual(@as(usize, 0), set_remote_calls);
    try std.testing.expectEqual(@as(usize, 0), add_remote_candidate_calls);
}

test "public webrtc signaling inputs are bounded before entering the sidecar" {
    set_remote_calls = 0;
    add_remote_candidate_calls = 0;
    var oversized: [webrtc.max_signal_bytes + 1]u8 = undefined;

    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);

    var peer: ?*webrtc_archive.GlowcapWebrtcPeer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_new(netlayer, 1, &peer));
    defer _ = webrtc_archive.glowcap_webrtc_peer_release(peer);

    try expectWebrtcSignalTooLarge(webrtc_archive.glowcap_webrtc_peer_set_remote_offer(peer, &oversized, oversized.len));
    try expectWebrtcSignalTooLarge(webrtc_archive.glowcap_webrtc_peer_set_remote_answer(peer, &oversized, oversized.len));
    try expectWebrtcCandidateTooLarge(webrtc_archive.glowcap_webrtc_peer_add_remote_candidate(peer, &oversized, oversized.len));
    try std.testing.expectEqual(@as(usize, 0), set_remote_calls);
    try std.testing.expectEqual(@as(usize, 0), add_remote_candidate_calls);
}

test "public webrtc generated signaling too large is not a retryable output buffer miss" {
    create_offer_result = -4;
    create_answer_result = -4;
    create_signal_len = webrtc.max_signal_bytes + 1;
    candidate_bytes_to_emit = webrtc.max_signal_bytes + 1;
    defer {
        create_offer_result = -2;
        create_answer_result = -2;
        create_signal_len = 0;
        candidate_bytes_to_emit = 0;
    }

    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);

    var peer: ?*webrtc_archive.GlowcapWebrtcPeer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_new(netlayer, 1, &peer));
    defer _ = webrtc_archive.glowcap_webrtc_peer_release(peer);

    var out: [1]u8 = undefined;
    var out_len: usize = 0;
    try expectWebrtcSignalTooLarge(webrtc_archive.glowcap_webrtc_peer_create_offer(peer, &out, out.len, &out_len));
    try std.testing.expectEqual(webrtc.max_signal_bytes + 1, out_len);
    try expectWebrtcSignalTooLarge(webrtc_archive.glowcap_webrtc_peer_create_answer(peer, &out, out.len, &out_len));
    try std.testing.expectEqual(webrtc.max_signal_bytes + 1, out_len);
    try expectWebrtcCandidateTooLarge(webrtc_archive.glowcap_webrtc_peer_next_local_candidate(peer, &out, out.len, &out_len));
    try std.testing.expectEqual(webrtc.max_signal_bytes + 1, out_len);
}

test "public webrtc remote authorization validates key designator before sidecar state" {
    open_result = 0;
    open_checks = 0;
    defer {
        open_result = -2;
        open_checks = 0;
    }

    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);

    var peer: ?*webrtc_archive.GlowcapWebrtcPeer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_new(netlayer, 1, &peer));
    defer _ = webrtc_archive.glowcap_webrtc_peer_release(peer);

    const short = "not-a-key";
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_peer_authorize_remote(peer, short.ptr, short.len));
    try expectWebrtcLastErrorContains("lowercase hex designator");
    try std.testing.expectEqual(@as(usize, 0), open_checks);

    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, webrtc_archive.glowcap_webrtc_peer_authorize_remote(peer, null, foundation.crypto.PeerKey.designator_len));
    try std.testing.expectEqual(@as(usize, 0), open_checks);
}

test "webrtc open failure stays distinct from clean close" {
    var peer: webrtc.Peer = .{ .peer = @ptrFromInt(104) };

    open_result = -5;
    open_checks = 0;
    try std.testing.expectError(error.Closed, peer.checkOpen());
    try std.testing.expectEqual(@as(usize, 1), open_checks);

    open_result = -1;
    try std.testing.expectError(error.Failed, peer.checkOpen());

    defer {
        open_result = -2;
        open_checks = 0;
    }

    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);

    var public_peer: ?*webrtc_archive.GlowcapWebrtcPeer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_new(netlayer, 1, &public_peer));
    defer _ = webrtc_archive.glowcap_webrtc_peer_release(public_peer);

    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, webrtc_archive.glowcap_webrtc_peer_is_open(public_peer));
    try expectWebrtcLastErrorContains("channel faulted");

    open_result = -5;
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, webrtc_archive.glowcap_webrtc_peer_is_open(public_peer));
}

fn expectWebrtcSignalTooLarge(code: i32) !void {
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, code);
    try expectWebrtcLastErrorContains("GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES");
}

fn expectWebrtcCandidateTooLarge(code: i32) !void {
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, code);
    try expectWebrtcLastErrorContains("GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES");
}

fn expectWebrtcLastErrorContains(message_part: []const u8) !void {
    var message: [256]u8 = undefined;
    const len = @min(webrtc_archive.glowcap_webrtc_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], message_part) != null);
}

test "public webrtc config validates nested ICE views before endpoint creation" {
    const empty_text: webrtc_archive.GlowcapWebrtcStringView = .{ .ptr = null, .len = 0 };
    var missing_urls = [_]webrtc_archive.GlowcapWebrtcIceServer{.{
        .urls = null,
        .url_count = 1,
        .username = empty_text,
        .credential = empty_text,
    }};
    var cfg: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    cfg.ice_servers = missing_urls[0..].ptr;
    cfg.ice_server_count = missing_urls.len;
    try expectWebrtcConfigRefusal(&cfg, c.GLOWCAP_ERR_NULL_POINTER, "null view");

    const stun = "stun:stun.example:3478";
    var urls = [_]webrtc_archive.GlowcapWebrtcStringView{.{ .ptr = stun.ptr, .len = stun.len }};
    missing_urls[0].urls = urls[0..].ptr;
    missing_urls[0].url_count = 0;
    try expectWebrtcConfigRefusal(&cfg, c.GLOWCAP_ERR_INVALID_ARGUMENT, "at least one URL");

    urls[0] = .{ .ptr = null, .len = 0 };
    missing_urls[0].url_count = 1;
    try expectWebrtcConfigRefusal(&cfg, c.GLOWCAP_ERR_INVALID_ARGUMENT, "must not be empty");

    const bad_scheme = "https://issuer.example/ice";
    urls[0] = .{ .ptr = bad_scheme.ptr, .len = bad_scheme.len };
    try expectWebrtcConfigRefusal(&cfg, c.GLOWCAP_ERR_INVALID_ARGUMENT, "must use stun:");

    const user = "short-lived-user";
    missing_urls[0].username = .{ .ptr = user.ptr, .len = user.len };
    urls[0] = .{ .ptr = stun.ptr, .len = stun.len };
    try expectWebrtcConfigRefusal(&cfg, c.GLOWCAP_ERR_INVALID_ARGUMENT, "STUN-only");

    const turn = "turn:turn.example:3478";
    urls[0] = .{ .ptr = turn.ptr, .len = turn.len };
    try expectWebrtcConfigRefusal(&cfg, c.GLOWCAP_ERR_INVALID_ARGUMENT, "both username and credential");

    const credential = "short-lived-secret";
    missing_urls[0].credential = .{ .ptr = credential.ptr, .len = credential.len };
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&cfg, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);
    try std.testing.expect(netlayer != null);
}

fn expectWebrtcConfigRefusal(
    cfg: *webrtc_archive.GlowcapWebrtcConfig,
    code: i32,
    message_part: []const u8,
) !void {
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = @ptrFromInt(1);
    try std.testing.expectEqual(code, webrtc_archive.glowcap_webrtc_netlayer_new(cfg, &netlayer));
    try std.testing.expectEqual(@as(?*webrtc_archive.GlowcapWebrtcNetlayer, null), netlayer);
    var message: [256]u8 = undefined;
    const len = @min(webrtc_archive.glowcap_webrtc_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], message_part) != null);
}

test "provider maps a clean WebRTC close to EOF" {
    open_result = -2;
    receive_result = 0;
    defer {
        open_result = -2;
        receive_result = -2;
    }

    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);

    var peer: ?*webrtc_archive.GlowcapWebrtcPeer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_new(netlayer, 1, &peer));
    defer _ = webrtc_archive.glowcap_webrtc_peer_release(peer);

    const key = foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x95))).publicKey();
    const designator = key.toDesignator();
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_authorize_remote(peer, &designator, designator.len));

    open_result = 0;
    const subject = webrtc_archive.glowcap_webrtc_peer_id(peer);
    var package: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_transport_provider(netlayer, &package));
    const transport = webrtcProviderTable(package);

    var failure = c.transport_provider.emptyProviderFailure();
    var conn: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, transport.claim_external.?(transport.ctx, subject, &conn, &failure));
    defer _ = transport.conn_close.?(transport.ctx, conn, &failure);

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), transport.try_read.?(transport.ctx, conn, &buf, buf.len));
    transport.conn_take_failure.?(transport.ctx, conn, &failure);
    try std.testing.expect(c.transport_provider.providerFailureEmpty(failure));
}

test "provider maps failed WebRTC open to transport failure" {
    open_result = -2;
    defer {
        open_result = -2;
    }

    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    defer _ = webrtc_archive.glowcap_webrtc_netlayer_release(netlayer);

    var peer: ?*webrtc_archive.GlowcapWebrtcPeer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_new(netlayer, 1, &peer));
    defer _ = webrtc_archive.glowcap_webrtc_peer_release(peer);

    const key = foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x31))).publicKey();
    const designator = key.toDesignator();
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_peer_authorize_remote(peer, &designator, designator.len));

    const subject = webrtc_archive.glowcap_webrtc_peer_id(peer);
    var package: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_transport_provider(netlayer, &package));
    const transport = webrtcProviderTable(package);

    open_result = -1;
    var failure = c.transport_provider.emptyProviderFailure();
    var conn: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, transport.claim_external.?(transport.ctx, subject, &conn, &failure));
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, failure.result);
}

test "candidate pump carries one candidate above the former 4 KiB bound" {
    candidate_bytes_to_emit = 5 * 1024;
    candidate_reads = 0;
    candidate_sent_bytes = 0;
    var resident: webrtc.Resident = .{ .endpoint = @ptrFromInt(1) };
    var backend = try webrtc.Backend.initBound(
        std.testing.allocator,
        &resident,
        .{ .ctx = undefined, .sendOffer = ignoreOffer, .sendCandidate = observeCandidate },
        1,
        64,
    );
    defer backend.deinit();

    var peer: webrtc.Peer = .{ .peer = @ptrFromInt(102) };
    var short: [4 * 1024]u8 = undefined;
    var required: usize = 0;
    try std.testing.expectError(error.BufferTooSmall, peer.nextLocalCandidate(&short, &required));
    try std.testing.expectEqual(@as(usize, 5 * 1024), required);
    try std.testing.expectEqual(@as(usize, 5 * 1024), candidate_bytes_to_emit);
    _ = try backend.adoptAnswerer(peer);
    var completions: [1]net.completion.Completion = undefined;
    _ = try backend.poll(&completions, 0);

    try std.testing.expectEqual(@as(usize, 5 * 1024), candidate_sent_bytes);
    try std.testing.expectEqual(@as(usize, 3), candidate_reads);
    try std.testing.expectEqual(@as(usize, 1), backend.adopting.count());
}

test "backend maps failed pre-open WebRTC peer distinctly from clean close" {
    open_result = -1;
    freed_peers = 0;
    defer {
        open_result = -2;
        freed_peers = 0;
    }

    var resident: webrtc.Resident = .{ .endpoint = @ptrFromInt(1) };
    var backend = try webrtc.Backend.initBound(
        std.testing.allocator,
        &resident,
        .{ .ctx = undefined, .sendOffer = ignoreOffer, .sendCandidate = ignoreCandidate },
        1,
        64,
    );
    defer backend.deinit();

    const peer: webrtc.Peer = .{ .peer = @ptrFromInt(105) };
    _ = try backend.adoptAnswerer(peer);
    var completions: [1]net.completion.Completion = undefined;
    _ = try backend.poll(&completions, 0);

    try std.testing.expectEqual(@as(usize, 1), freed_peers);
    try std.testing.expectEqual(@as(usize, 0), backend.adopting.count());
    try std.testing.expectEqual(@as(usize, 1), backend.accept_stash.items.len);
    try std.testing.expectEqual(error.WebRtcChannelFailed, backend.accept_stash.items[0].failed);
}

test "adopted peer reports the signaling-authorized channel key" {
    var resident: webrtc.Resident = .{ .endpoint = @ptrFromInt(1) };
    var backend = try webrtc.Backend.initBound(
        std.testing.allocator,
        &resident,
        .{ .ctx = undefined, .sendOffer = ignoreOffer, .sendCandidate = ignoreCandidate },
        1,
        64,
    );
    defer backend.deinit();

    const key = foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x72))).publicKey();
    const fd: i32 = 7;
    var peer: webrtc.Peer = .{ .peer = @ptrFromInt(103) };
    peer.authorizeRemote(key);
    try backend.by_id.put(@backingInt(peer.id()), fd);
    try backend.conns.put(fd, .{ .peer = peer });

    try std.testing.expectEqualSlices(u8, key.asBytes(), &(backend.verifiedChannelKey(fd) orelse return error.MissingChannelKey));
    try std.testing.expectEqual(@as(?[foundation.crypto.PEER_KEY_BYTES]u8, null), backend.verifiedChannelKey(fd + 1));
}

test "signal drain failure retires current row and retries the next exactly once" {
    freed_peers = 0;
    var resident: webrtc.Resident = .{ .endpoint = @ptrFromInt(1) };
    var backend = try webrtc.Backend.initBound(
        std.testing.allocator,
        &resident,
        .{ .ctx = undefined, .sendOffer = ignoreOffer, .sendCandidate = ignoreCandidate },
        1,
        64,
    );
    defer backend.deinit();

    while (backend.accept_stash.items.len < 128) {
        backend.accept_stash.appendAssumeCapacity(.{ .failed = error.TestBacklog });
    }
    const first_fd: i32 = 41;
    const first_peer: webrtc.Peer = .{ .peer = @ptrFromInt(101) };
    try backend.adopting.put(first_fd, .{ .peer = first_peer });
    try backend.by_id.put(@backingInt(first_peer.id()), first_fd);

    try backend.provideRemoteCandidate(first_fd, "first");
    try backend.provideRemoteCandidate(42, "second");
    var completions: [4]net.completion.Completion = undefined;
    try std.testing.expectError(error.AcceptBacklogFull, backend.poll(&completions, 0));

    try std.testing.expectEqual(@as(usize, 1), freed_peers);
    try std.testing.expectEqual(@as(usize, 0), backend.adopting.count());
    try std.testing.expectEqual(@as(usize, 1), backend.signal_work.items.len);
    try std.testing.expectEqual(@as(i32, 42), backend.signal_work.items[0].candidate.fd);
    try std.testing.expectEqual(@as(usize, 255), backend.signal_payloads.free_len);

    _ = try backend.poll(&completions, 0);
    try std.testing.expectEqual(@as(usize, 0), backend.signal_work.items.len);
    try std.testing.expectEqual(@as(usize, 256), backend.signal_payloads.free_len);
    try std.testing.expectEqual(@as(usize, 1), freed_peers);
}
