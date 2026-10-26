//! The scripted Rust library behind the iroh tests. Every imported verb
//! answers from the knobs here, so a test can script a connection, an accept,
//! a readiness batch, or a library that breaks its contract, and the test
//! files share one script instead of each linking its own.

const foundation = @import("foundation");
const iroh = @import("iroh");

pub var conn_free_count: usize = 0;
pub var admission_enabled = false;
pub var admission_fails = false;
pub var ready_records: usize = 0;
pub var cancel_calls: usize = 0;
pub var io_result: isize = iroh.loop_would_block;
pub var dial_start_result: i32 = 0;
pub var next_connect: ?*anyopaque = null;
pub var next_accept: ?*anyopaque = null;
pub var endpoint_closed = false;
pub var direct_required: usize = 0;
pub var node_id_fails = false;
pub var remote_key: [foundation.crypto.peer_key_bytes]u8 = @as([foundation.crypto.peer_key_bytes]u8, @splat(0x61));
pub var emit_sidecar_accept = false;
/// A readiness drain reports one record more than the buffer offered.
pub var ready_past_cap = false;
/// Connections `try_accept` still hands out, each with its own handle.
pub var accept_burst: usize = 0;

pub fn reset() void {
    conn_free_count = 0;
    admission_enabled = false;
    admission_fails = false;
    ready_records = 0;
    cancel_calls = 0;
    io_result = iroh.loop_would_block;
    dial_start_result = 0;
    next_connect = null;
    next_accept = null;
    endpoint_closed = false;
    direct_required = 0;
    node_id_fails = false;
    remote_key = @splat(0x61);
    emit_sidecar_accept = false;
    ready_past_cap = false;
    accept_burst = 0;
}

export fn glowcap_iroh_sidecar_endpoint_new(_: ?*const [32]u8, _: *const anyopaque) callconv(.c) ?*anyopaque {
    return @ptrFromInt(1);
}
export fn glowcap_iroh_sidecar_endpoint_node_id(_: *const anyopaque, out: [*]u8, out_cap: usize) callconv(.c) isize {
    if (node_id_fails) return -1;
    if (out_cap < iroh.node_id_len) return iroh.node_id_len;
    @memset(out[0..iroh.node_id_len], '0');
    return iroh.node_id_len;
}
export fn glowcap_iroh_sidecar_endpoint_direct_addrs(_: *const anyopaque, out: [*]u8, out_cap: usize) callconv(.c) isize {
    if (out_cap < direct_required) return @intCast(direct_required);
    @memset(out[0..direct_required], 'a');
    return @intCast(direct_required);
}
export fn glowcap_iroh_sidecar_connect_blocking(_: *anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, out_code: *i32) callconv(.c) ?*anyopaque {
    out_code.* = 0;
    const conn = next_connect;
    next_connect = null;
    return conn;
}
export fn glowcap_iroh_sidecar_accept_timeout(_: *anyopaque, _: i32, out_code: *i32) callconv(.c) ?*anyopaque {
    const conn = next_accept;
    next_accept = null;
    out_code.* = if (conn != null) 0 else if (endpoint_closed) 4 else 2;
    return conn;
}
export fn glowcap_iroh_sidecar_conn_remote_node_id(_: *const anyopaque, out: [*]u8) callconv(.c) i32 {
    @memcpy(out[0..remote_key.len], &remote_key);
    return 0;
}
export fn glowcap_iroh_sidecar_conn_read(_: *anyopaque, _: [*]u8, _: usize) callconv(.c) isize {
    return -1;
}
export fn glowcap_iroh_sidecar_conn_write(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) isize {
    return -1;
}
export fn glowcap_iroh_sidecar_conn_flush(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_iroh_sidecar_conn_close(_: *anyopaque) callconv(.c) void {}
export fn glowcap_iroh_sidecar_conn_free(_: *anyopaque) callconv(.c) void {
    conn_free_count += 1;
}
export fn glowcap_iroh_sidecar_endpoint_close(_: *anyopaque) callconv(.c) void {
    endpoint_closed = true;
}
export fn glowcap_iroh_sidecar_endpoint_free(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_iroh_sidecar_endpoint_readiness_fd(_: *const anyopaque) callconv(.c) i32 {
    return 100;
}
export fn glowcap_iroh_sidecar_endpoint_drain_ready(_: *const anyopaque, out: [*]iroh.ReadyEvent, out_cap: usize) callconv(.c) isize {
    if (ready_past_cap) return @intCast(out_cap + 1);
    if (ready_records != 0) {
        const count = @min(ready_records, out_cap);
        for (out[0..count], 0..) |*event, i| event.* = .{ .subject = i + 100, .events = iroh.loop_ev_readable };
        ready_records -= count;
        return @intCast(count);
    }
    if (!emit_sidecar_accept or out_cap == 0) return 0;
    emit_sidecar_accept = false;
    out[0] = .{ .subject = 0, .events = iroh.loop_ev_accept };
    return 1;
}
export fn glowcap_iroh_sidecar_endpoint_start_connect(_: *anyopaque, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) i32 {
    return dial_start_result;
}
export fn glowcap_iroh_sidecar_endpoint_finish_connect(_: *anyopaque, _: usize, out_conn: *?*anyopaque, _: ?[*]u8, _: usize, out_text_len: ?*usize) callconv(.c) i32 {
    if (out_text_len) |slot| slot.* = 0;
    out_conn.* = next_connect;
    next_connect = null;
    return if (out_conn.* != null) 0 else -1;
}
export fn glowcap_iroh_sidecar_endpoint_cancel_connect(_: *anyopaque, _: usize) callconv(.c) i32 {
    cancel_calls += 1;
    return 0;
}
export fn glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_iroh_sidecar_endpoint_admission(_: *anyopaque, enabled: u8) callconv(.c) i32 {
    if (admission_fails) return -1;
    admission_enabled = enabled != 0;
    if (!admission_enabled) next_accept = null;
    return 0;
}
export fn glowcap_iroh_sidecar_endpoint_try_accept(_: *anyopaque) callconv(.c) ?*anyopaque {
    if (accept_burst != 0) {
        accept_burst -= 1;
        return @ptrFromInt(0x1000 + accept_burst);
    }
    const conn = next_accept;
    next_accept = null;
    return conn;
}
export fn glowcap_iroh_sidecar_conn_set_nonblocking(_: *anyopaque, _: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn glowcap_iroh_sidecar_conn_id(conn: *const anyopaque) callconv(.c) usize {
    return @intFromPtr(conn);
}
export fn glowcap_iroh_sidecar_conn_try_read(_: *anyopaque, _: [*]u8, _: usize) callconv(.c) isize {
    return io_result;
}
export fn glowcap_iroh_sidecar_conn_try_write(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) isize {
    return io_result;
}
