//! Link-time stubs for the iroh sidecar's C ABI
//! (`transports/iroh/include/glowcap_iroh_sidecar.h`).
//!
//! The iroh public C ABI (`src/c_abi/net_transport/iroh/mod.zig`) and the Zig
//! resident (`src/net/transport/iroh.zig`) call the Rust sidecar through
//! `extern fn glowcap_iroh_sidecar_*` declarations. Those symbols only exist once
//! `libglowcap_iroh_sidecar.a` is
//! linked, which needs cargo. The header generator
//! (`tools/gen/header/iroh.zig`) only *reflects* over the module's types and
//! signatures, never calling them, but the generator executable still has to
//! link. These stubs satisfy the linker for build-time reflection and for CLI
//! tests that exercise no live iroh path, keeping `zig build check` independent
//! of Cargo's machine-local cache. The real sidecar replaces them in
//! `libglowcap_net_transport_iroh` and every live iroh proof.
//!
//! Every body traps: linking these into anything that actually dials iroh is a
//! build-wiring mistake, and it should fail loud rather than silently no-op.

const msg = "iroh sidecar stub: reflection/test link only; link libglowcap_iroh_sidecar.a to run";

const EndpointConfig = extern struct {
    reachability: u32,
    connect_timeout_ms: u64,
    idle_timeout_ms: u64,
    worker_threads: u32,
};

export fn glowcap_iroh_sidecar_endpoint_new(secret_seed32: ?*const [32]u8, config: *const EndpointConfig) ?*anyopaque {
    _ = .{ secret_seed32, config };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_node_id(ep: *const anyopaque, out: [*]u8, out_cap: usize) isize {
    _ = .{ ep, out, out_cap };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_direct_addrs(ep: *const anyopaque, out: [*]u8, out_cap: usize) isize {
    _ = .{ ep, out, out_cap };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_connect_blocking(
    ep: *anyopaque,
    node_id: [*]const u8,
    node_id_len: usize,
    addr_hints: [*]const u8,
    addr_hints_len: usize,
    out_code: *i32,
    out_text: ?[*]u8,
    out_text_cap: usize,
    out_text_len: ?*usize,
) ?*anyopaque {
    _ = .{ ep, node_id, node_id_len, addr_hints, addr_hints_len, out_code, out_text, out_text_cap, out_text_len };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_accept_timeout(ep: *anyopaque, timeout_ms: i32, out_code: *i32) ?*anyopaque {
    _ = .{ ep, timeout_ms, out_code };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_read(conn: *anyopaque, buf: [*]u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_write(conn: *anyopaque, buf: [*]const u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_flush(conn: *anyopaque) i32 {
    _ = conn;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_close(conn: *anyopaque) void {
    _ = conn;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_free(conn: *anyopaque) void {
    _ = conn;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_close(ep: *anyopaque) void {
    _ = ep;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_free(ep: *anyopaque) i32 {
    _ = ep;
    @panic(msg);
}

export fn glowcap_iroh_sidecar_endpoint_readiness_fd(ep: *const anyopaque) i32 {
    _ = ep;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_drain_ready(ep: *const anyopaque, out: *anyopaque, out_cap: usize) isize {
    _ = .{ ep, out, out_cap };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_start_connect(ep: *anyopaque, request_id: usize, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize) i32 {
    _ = .{ ep, request_id, node_id, node_id_len, addr_hints, addr_hints_len };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_finish_connect(ep: *anyopaque, request_id: usize, out_conn: *?*anyopaque, out_text: ?[*]u8, out_text_cap: usize, out_text_len: ?*usize) i32 {
    _ = .{ ep, request_id, out_conn, out_text, out_text_cap, out_text_len };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_cancel_connect(ep: *anyopaque, request_id: usize) i32 {
    _ = .{ ep, request_id };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *anyopaque) i32 {
    _ = ep;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_endpoint_admission(ep: *anyopaque, enabled: u8) i32 {
    _ = .{ ep, enabled };
    @panic(msg);
}

export fn glowcap_iroh_sidecar_endpoint_try_accept(ep: *anyopaque) ?*anyopaque {
    _ = ep;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_set_nonblocking(ep: *anyopaque, conn: *anyopaque) i32 {
    _ = .{ ep, conn };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_id(conn: *const anyopaque) usize {
    _ = conn;
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_remote_node_id(conn: *const anyopaque, out_key32: [*]u8) i32 {
    _ = .{ conn, out_key32 };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_try_read(conn: *anyopaque, buf: [*]u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
export fn glowcap_iroh_sidecar_conn_try_write(conn: *anyopaque, buf: [*]const u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
