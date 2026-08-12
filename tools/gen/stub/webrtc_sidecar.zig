//! Link-time stubs for the WebRTC sidecar's C ABI
//! (`transports/webrtc/src/lib.rs`, the `pancake_webrtc_sidecar_*` family).
//!
//! The WebRTC public C ABI (`src/c_abi/net_transport/webrtc/mod.zig`) and the
//! Zig resident (`src/net/transport/webrtc.zig`) call the Rust sidecar through
//! `extern fn pancake_webrtc_sidecar_*` declarations. Those symbols only exist
//! once `libpancake_webrtc_sidecar.a` is linked, which needs cargo. The header
//! generator (`tools/gen/header/webrtc.zig`) only *reflects* over the module's
//! types and signatures, never calling them, but the generator executable still
//! has to link. These stubs satisfy the linker so
//! `zig build gen-header-net-transport-webrtc{,-check}` runs cargo-free; the
//! real sidecar replaces them in `libpancake_net_transport_webrtc`.
//!
//! Every body traps: linking these into anything that actually drives a
//! DataChannel is a build-wiring mistake, and it should fail loud rather than
//! silently no-op.

const msg = "webrtc sidecar stub: build-time only (header generation); link libpancake_webrtc_sidecar.a to run";

export fn pancake_webrtc_sidecar_endpoint_new(config: *const anyopaque) ?*anyopaque {
    _ = config;
    @panic(msg);
}
export fn pancake_webrtc_sidecar_endpoint_readiness_fd(endpoint: *const anyopaque) i32 {
    _ = endpoint;
    @panic(msg);
}
export fn pancake_webrtc_sidecar_endpoint_drain_ready(endpoint: *const anyopaque, out: *anyopaque, out_cap: usize) isize {
    _ = .{ endpoint, out, out_cap };
    @panic(msg);
}

export fn pancake_webrtc_sidecar_endpoint_driver_readiness_fd(endpoint: *const anyopaque) i32 {
    _ = endpoint;
    return -1;
}

export fn pancake_webrtc_sidecar_endpoint_drain_driver_ready(endpoint: *const anyopaque, out: *anyopaque, out_cap: usize) isize {
    _ = endpoint;
    _ = out;
    _ = out_cap;
    return -1;
}
export fn pancake_webrtc_sidecar_endpoint_free(endpoint: *anyopaque) void {
    _ = endpoint;
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_new(endpoint: *anyopaque, is_offerer: i32) ?*anyopaque {
    _ = .{ endpoint, is_offerer };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_create_offer(peer: *anyopaque, out: [*]u8, cap: usize, out_len: *usize) i32 {
    _ = .{ peer, out, cap, out_len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_create_answer(peer: *anyopaque, out: [*]u8, cap: usize, out_len: *usize) i32 {
    _ = .{ peer, out, cap, out_len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_set_remote(peer: *anyopaque, sdp: [*]const u8, sdp_len: usize, is_offer: i32) i32 {
    _ = .{ peer, sdp, sdp_len, is_offer };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_add_remote_candidate(peer: *anyopaque, cand: [*]const u8, cand_len: usize) i32 {
    _ = .{ peer, cand, cand_len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_next_local_candidate(peer: *anyopaque, out: [*]u8, cap: usize, out_len: *usize) i32 {
    _ = .{ peer, out, cap, out_len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_id(peer: *const anyopaque) usize {
    _ = peer;
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_is_open(peer: *const anyopaque) i32 {
    _ = peer;
    @panic(msg);
}
export fn pancake_webrtc_sidecar_conn_read(peer: *anyopaque, buf: [*]u8, len: usize) isize {
    _ = .{ peer, buf, len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_conn_write(peer: *anyopaque, buf: [*]const u8, len: usize) isize {
    _ = .{ peer, buf, len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_conn_try_read(peer: *anyopaque, buf: [*]u8, len: usize) isize {
    _ = .{ peer, buf, len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_conn_try_write(peer: *anyopaque, buf: [*]const u8, len: usize) isize {
    _ = .{ peer, buf, len };
    @panic(msg);
}
export fn pancake_webrtc_sidecar_conn_close(peer: *anyopaque) void {
    _ = peer;
    @panic(msg);
}
export fn pancake_webrtc_sidecar_peer_free(peer: *anyopaque) void {
    _ = peer;
    @panic(msg);
}
