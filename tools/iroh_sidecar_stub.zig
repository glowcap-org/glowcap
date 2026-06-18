//! Link-time stubs for the iroh sidecar's C ABI
//! (`transports/iroh/include/pancake_iroh_sidecar.h`).
//!
//! The iroh public C ABI (`src/c_abi/net_transport/iroh/mod.zig`) and the Zig
//! resident (`src/net/transport/iroh.zig`) call the Rust sidecar through
//! `extern fn pancake_iroh_sidecar_*` declarations. Those symbols only exist once
//! `libpancake_iroh_sidecar.a` is
//! linked — which needs cargo. The header generator
//! (`tools/header_gen_iroh.zig`) only *reflects* over the module's types and
//! signatures, never calling them, but the generator executable still has to
//! link. These stubs satisfy the linker so
//! `zig build gen-header-net-transport-iroh{,-check}` runs cargo-free; the real
//! sidecar replaces them in `libpancake_net_transport_iroh`.
//!
//! Every body traps: linking these into anything that actually dials iroh is a
//! build-wiring mistake, and it should fail loud rather than silently no-op.

const msg = "iroh sidecar stub: build-time only (header generation); link libpancake_iroh_sidecar.a to run";

export fn pancake_iroh_sidecar_endpoint_new(secret_seed32: ?*const [32]u8, reachability: u32) ?*anyopaque {
    _ = .{ secret_seed32, reachability };
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_node_id(ep: *const anyopaque, out: [*]u8, out_cap: usize) isize {
    _ = .{ ep, out, out_cap };
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_direct_addrs(ep: *const anyopaque, out: [*]u8, out_cap: usize) isize {
    _ = .{ ep, out, out_cap };
    @panic(msg);
}
export fn pancake_iroh_sidecar_connect(
    ep: *anyopaque,
    node_id: [*]const u8,
    node_id_len: usize,
    addr_hints: [*]const u8,
    addr_hints_len: usize,
) ?*anyopaque {
    _ = .{ ep, node_id, node_id_len, addr_hints, addr_hints_len };
    @panic(msg);
}
export fn pancake_iroh_sidecar_accept(ep: *anyopaque) ?*anyopaque {
    _ = ep;
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_read(conn: *anyopaque, buf: [*]u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_write(conn: *anyopaque, buf: [*]const u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_flush(conn: *anyopaque) i32 {
    _ = conn;
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_close(conn: *anyopaque) void {
    _ = conn;
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_free(conn: *anyopaque) void {
    _ = conn;
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_close(ep: *anyopaque) void {
    _ = ep;
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_free(ep: *anyopaque) void {
    _ = ep;
    @panic(msg);
}

export fn pancake_iroh_sidecar_endpoint_readiness_fd(ep: *const anyopaque) i32 {
    _ = ep;
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_drain_ready(ep: *const anyopaque, out: *anyopaque, out_cap: usize) isize {
    _ = .{ ep, out, out_cap };
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *anyopaque) i32 {
    _ = ep;
    @panic(msg);
}
export fn pancake_iroh_sidecar_endpoint_try_accept(ep: *anyopaque) ?*anyopaque {
    _ = ep;
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_set_nonblocking(ep: *anyopaque, conn: *anyopaque) i32 {
    _ = .{ ep, conn };
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_try_read(conn: *anyopaque, buf: [*]u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
export fn pancake_iroh_sidecar_conn_try_write(conn: *anyopaque, buf: [*]const u8, len: usize) isize {
    _ = .{ conn, buf, len };
    @panic(msg);
}
