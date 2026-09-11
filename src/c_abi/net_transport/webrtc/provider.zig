//! Generic multiplexed-provider projection of the WebRTC ownership graph.
//!
//! Signaling remains in the public WebRTC ABI. This leaf only lets the driver
//! claim an already-authorized open peer and perform nonblocking packet I/O.

const std = @import("std");

const crypto = @import("foundation").crypto;
const c = @import("c_abi_shared");
const webrtc = @import("webrtc");
const ownership = @import("ownership.zig");

const NetlayerPayload = ownership.NetlayerPayload;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;
const transport_name = "webrtc";

fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    return payload.resident.driverReadinessFd();
}

fn drainReady(ctx: ?*anyopaque, out: ?[*]c.GlowcapMultiplexedReadyEvent, cap: usize, out_count: ?*usize, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const count = out_count orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const dest = out orelse if (cap == 0) null else return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var total: usize = 0;

    var raw: [1]webrtc.ReadyEvent = undefined;
    while (total < cap) {
        const n = payload.resident.drainDriverReady(&raw) catch |err| return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
        if (n == 0) break;
        const event = raw[0];
        const peer = payload.peers.get(event.subject) orelse continue;
        if (!peer.provider_claimed) continue;
        var mapped: u32 = 0;
        if (event.events & webrtc.ev_readable != 0) mapped |= c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE;
        if (event.events & webrtc.ev_writable != 0) mapped |= c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_WRITABLE;
        if (event.events & webrtc.ev_closed != 0) mapped |= c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CLOSED;
        if (mapped == 0) continue;
        dest.?[total] = .{ .subject = @intCast(event.subject), .events = mapped };
        total += 1;
    }
    count.* = total;
    return GLOWCAP_OK;
}

fn claimExternal(ctx: ?*anyopaque, subject: u64, out_conn: ?*u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const peer = payload.peers.get(@intCast(subject)) orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    if (peer.provider_claimed or peer.peer.authorized_remote == null)
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    peer.peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_WOULD_BLOCK, err),
        error.Closed => c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_CLOSED, err),
        error.Failed => c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err),
    };
    peer.provider_claimed = true;
    peer.references += 1;
    slot.* = subject;
    return GLOWCAP_OK;
}

fn tryRead(ctx: ?*anyopaque, conn: u64, buf: ?[*]u8, cap: usize) callconv(.c) isize {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const dest = buf orelse return -1;
    const peer = payload.peers.get(@intCast(conn)) orelse return -1;
    if (!peer.provider_claimed) return -1;
    const n = peer.peer.tryReceivePacket(dest[0..cap]) catch |err| {
        if (err == error.WouldBlock) return c.multiplexed_transport.GLOWCAP_MULTIPLEXED_WOULD_BLOCK;
        if (err == error.Closed) return 0;
        if (c.transport_provider.providerFailureEmpty(peer.failure))
            c.transport_provider.setProviderFailure(&peer.failure, GLOWCAP_ERR_IO, err);
        return -1;
    };
    return @intCast(n);
}

fn tryWrite(ctx: ?*anyopaque, conn: u64, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const src = bytes orelse return -1;
    const peer = payload.peers.get(@intCast(conn)) orelse return -1;
    if (!peer.provider_claimed) return -1;
    const n = peer.peer.trySendPacket(src[0..len]) catch |err| {
        if (err == error.WouldBlock) return c.multiplexed_transport.GLOWCAP_MULTIPLEXED_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(peer.failure))
            c.transport_provider.setProviderFailure(&peer.failure, GLOWCAP_ERR_IO, err);
        return -1;
    };
    return @intCast(n);
}

fn connTakeFailure(ctx: ?*anyopaque, conn: u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) void {
    const slot = out_failure orelse return;
    slot.* = std.mem.zeroes(c.GlowcapProviderFailure);
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const peer = payload.peers.get(@intCast(conn)) orelse return;
    if (!peer.provider_claimed) return;
    slot.* = peer.failure;
    peer.failure = std.mem.zeroes(c.GlowcapProviderFailure);
}

fn connClose(ctx: ?*anyopaque, conn: u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const key: usize = @intCast(conn);
    const peer = payload.peers.get(key) orelse return GLOWCAP_OK;
    if (!peer.provider_claimed) return GLOWCAP_OK;
    peer.peer.close();
    peer.provider_claimed = false;
    std.debug.assert(payload.peers.remove(key));
    if (ownership.releasePeer(peer)) |failure|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, failure);
    return GLOWCAP_OK;
}

fn connRemoteKey(ctx: ?*anyopaque, conn: u64, out_key: ?[*]u8) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const dest = out_key orelse return GLOWCAP_ERR_NULL_POINTER;
    const peer = payload.peers.get(@intCast(conn)) orelse return 0;
    if (!peer.provider_claimed) return 0;
    peer.peer.checkOpen() catch return 0;
    const key = peer.peer.authorized_remote orelse return 0;
    @memcpy(dest[0..crypto.PEER_KEY_BYTES], key.asBytes());
    return 1;
}

fn retain(ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return GLOWCAP_ERR_NULL_POINTER;
    }));
    if (ownership.retainNetlayer(payload)) return GLOWCAP_OK;
    c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_CLOSED, error.Closed);
    return GLOWCAP_ERR_CLOSED;
}

fn release(ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse return GLOWCAP_OK));
    if (ownership.releaseNetlayer(payload)) |failure|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, failure);
    return GLOWCAP_OK;
}

fn sameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    return @intFromBool(ctx == other_ctx);
}

fn ensureInitialized(payload: *NetlayerPayload) void {
    if (payload.provider_initialized) return;
    payload.provider_profile = .{
        .abi_version = c.transport_provider.GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapTransportProfile),
        .transport_name = transport_name.ptr,
        .transport_name_len = transport_name.len,
        .designator_scheme = c.transport_provider.GLOWCAP_DESIGNATOR_SCHEME_KEY,
        .sealed_channel = c.transport_provider.GLOWCAP_SEALED_CHANNEL_NONE,
        .wire_framing = c.transport_provider.GLOWCAP_WIRE_FRAMING_MESSAGE,
        .max_packet_bytes = webrtc.max_packet_bytes,
    };
    payload.multiplexed_transport = .{
        .abi_version = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapMultiplexedTransport),
        .ctx = payload,
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .start_connect = null,
        .finish_connect = null,
        .claim_external = claimExternal,
        .cancel_connect = null,
        .listen = null,
        .finish_listen = null,
        .cancel_listen = null,
        .listener_locator = null,
        .listener_advertise = null,
        .finish_accept = null,
        .stop_listen = null,
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_take_failure = connTakeFailure,
        .conn_remote_key = connRemoteKey,
    };
    payload.provider_entry = .{
        .profile = &payload.provider_profile,
        .execution_model = c.transport_provider.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = &payload.multiplexed_transport,
    };
    payload.provider_initialized = true;
}

pub fn fill(payload: *NetlayerPayload, slot: *c.GlowcapTransportProvider) void {
    ensureInitialized(payload);
    slot.* = .{
        .abi_version = c.transport_provider.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapTransportProvider),
        .entries = @ptrCast(&payload.provider_entry),
        .entry_count = 1,
        .lease_ctx = payload,
        .same_configuration = sameConfiguration,
        .retain = retain,
        .release = release,
    };
}
