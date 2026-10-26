//! A scripted stand-in for the WebRTC Rust sidecar, linked in place of the
//! real one so the resident, the backend, and the C module can be tested
//! without cargo. Each export answers from the variables below, and the tests
//! set them before a call and reset them after. Return codes follow
//! `sidecar.zig`: 0 ok, -1 failed, -2 would block, -3 buffer too small,
//! -4 signal too large, -5 closed. Peers get ids counting from 2, and a
//! fixture resets the count, so a test's first peer has id 2.

const webrtc = @import("webrtc");

pub var freed_peers: usize = 0;
pub var next_connection_id: usize = 2;
pub var candidate_bytes_to_emit: usize = 0;
/// Answer ok with the full emit length even past the buffer offered, writing
/// only the bytes that fit: a library breaking the result contract.
pub var candidate_ok_past_cap: bool = false;
pub var candidate_reads: usize = 0;
pub var candidate_sent_bytes: usize = 0;
pub var create_offer_result: i32 = -2;
pub var create_answer_result: i32 = -2;
pub var create_signal_len: usize = 0;
pub var set_remote_calls: usize = 0;
pub var set_remote_result: i32 = -1;
pub var add_remote_candidate_calls: usize = 0;
pub var add_remote_candidate_result: i32 = -1;
pub var open_result: i32 = -2;
pub var open_checks: usize = 0;
pub var receive_result: isize = -2;

/// Records the next `drain_driver_ready` hands the driver, then clears.
pub var driver_events: [8]webrtc.ReadyEvent = undefined;
pub var driver_event_count: usize = 0;

/// The id of the peer created last.
pub fn lastPeer() usize {
    return next_connection_id - 1;
}

/// Queue one readiness record for the driver-facing drain.
pub fn pushDriverEvent(subject: usize, events: u32) void {
    driver_events[driver_event_count] = .{ .subject = subject, .events = events };
    driver_event_count += 1;
}

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
export fn glowcap_webrtc_sidecar_endpoint_drain_driver_ready(_: *const anyopaque, out: [*]webrtc.ReadyEvent, cap: usize) callconv(.c) isize {
    const n = @min(cap, driver_event_count);
    @memcpy(out[0..n], driver_events[0..n]);
    driver_event_count = 0;
    return @intCast(n);
}
export fn glowcap_webrtc_sidecar_endpoint_free(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_webrtc_sidecar_peer_new(_: *anyopaque, _: i32) callconv(.c) ?*anyopaque {
    const id = next_connection_id;
    next_connection_id += 1;
    return @ptrFromInt(id);
}
export fn glowcap_webrtc_sidecar_peer_id(peer: *const anyopaque) callconv(.c) usize {
    return @intFromPtr(peer);
}
export fn glowcap_webrtc_sidecar_peer_create_offer(_: *anyopaque, out: [*]u8, cap: usize, out_len: *usize) callconv(.c) i32 {
    out_len.* = create_signal_len;
    if (create_offer_result == 0) @memset(out[0..@min(cap, create_signal_len)], 'o');
    return create_offer_result;
}
export fn glowcap_webrtc_sidecar_peer_create_answer(_: *anyopaque, _: [*]u8, _: usize, out_len: *usize) callconv(.c) i32 {
    out_len.* = create_signal_len;
    return create_answer_result;
}
export fn glowcap_webrtc_sidecar_peer_add_remote_candidate(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) i32 {
    add_remote_candidate_calls += 1;
    return add_remote_candidate_result;
}
export fn glowcap_webrtc_sidecar_peer_set_remote(_: *anyopaque, _: [*]const u8, _: usize, _: i32) callconv(.c) i32 {
    set_remote_calls += 1;
    return set_remote_result;
}
export fn glowcap_webrtc_sidecar_peer_next_local_candidate(_: *anyopaque, out: [*]u8, cap: usize, out_len: *usize) callconv(.c) i32 {
    candidate_reads += 1;
    if (candidate_bytes_to_emit != 0) {
        out_len.* = candidate_bytes_to_emit;
        if (candidate_bytes_to_emit > cap and !candidate_ok_past_cap) return -3;
        @memset(out[0..@min(cap, candidate_bytes_to_emit)], 'c');
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
/// Closing publishes the peer's closed record, as the sidecar does.
export fn glowcap_webrtc_sidecar_conn_close(peer: *anyopaque) callconv(.c) void {
    pushDriverEvent(@intFromPtr(peer), webrtc.ev_closed);
}
export fn glowcap_webrtc_sidecar_peer_free(_: *anyopaque) callconv(.c) void {
    freed_peers += 1;
}
