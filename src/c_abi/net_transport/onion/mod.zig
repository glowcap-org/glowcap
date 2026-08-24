//! Stable C facade for the native onion provider archive.
//!
//! The facade owns opaque-handle validation, construction, teardown, and the
//! fixed C surface. `provider/` projects the generic stream-provider contract;
//! `framed/` projects blocking managed-frame handles. Tor control, SOCKS, onion
//! service lifecycle, and socket policy remain in `net.onion`.

const std = @import("std");
const c = @import("c_abi_shared");
const contract = @import("contract.zig");
const create_runtime = @import("runtime/create.zig");
const runtime = @import("runtime/state.zig");
const provider = @import("provider/mod.zig");
const framed = @import("framed/mod.zig");
const failure_projection = @import("failure.zig");

pub const PancakeOnionNetlayer = contract.PancakeOnionNetlayer;
pub const PancakeOnionConn = contract.PancakeOnionConn;
pub const PancakeOnionListener = contract.PancakeOnionListener;
pub const PancakeOnionConfig = contract.PancakeOnionConfig;
pub const contract_layouts = [_]c.archive_contract.Layout{
    c.archive_contract.layout("PANCAKE_ONION_CONFIG", PancakeOnionConfig),
};
pub const PANCAKE_ONION_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "onion",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);
pub const PANCAKE_ONION_AUTH_NONE = contract.PANCAKE_ONION_AUTH_NONE;
pub const PANCAKE_ONION_AUTH_COOKIE = contract.PANCAKE_ONION_AUTH_COOKIE;
pub const PANCAKE_ONION_AUTH_PASSWORD = contract.PANCAKE_ONION_AUTH_PASSWORD;
pub const PANCAKE_ONION_SERVICE_ID_LEN = contract.PANCAKE_ONION_SERVICE_ID_LEN;
pub const PANCAKE_ONION_SERVICE_KEY_CAP = contract.PANCAKE_ONION_SERVICE_KEY_CAP;

const PancakeContext = c.PancakeContext;
pub const symbols = @import("symbols.zig");

pub export fn pancake_onion_archive_fingerprint() u64 {
    return PANCAKE_ONION_ARCHIVE_FINGERPRINT;
}

pub export fn pancake_onion_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

pub export fn pancake_onion_clear_last_error() void {
    c.lastErrorClear();
}

pub export fn pancake_onion_netlayer_new(
    config: ?*const PancakeOnionConfig,
    out_netlayer: ?*?*PancakeOnionNetlayer,
) i32 {
    c.lastErrorClear();
    const slot = out_netlayer orelse return c.PANCAKE_ERR_NULL_POINTER;
    const value = config orelse return c.PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, value, slot);
}

pub export fn pancake_onion_netlayer_new_in(
    context: ?*PancakeContext,
    config: ?*const PancakeOnionConfig,
    out_netlayer: ?*?*PancakeOnionNetlayer,
) i32 {
    c.lastErrorClear();
    const c_context = c.ctxFromOpaque(context) orelse return c.PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return c.PANCAKE_ERR_NULL_POINTER;
    const value = config orelse return c.PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_context.allocator(), value, slot);
}

fn netlayerNewIn(
    allocator: std.mem.Allocator,
    config: *const PancakeOnionConfig,
    out: *?*PancakeOnionNetlayer,
) i32 {
    var payload: ?*runtime.Netlayer = null;
    const result = create_runtime.create(allocator, config, &payload);
    out.* = if (payload) |value| @ptrCast(value) else null;
    return result;
}

pub export fn pancake_onion_transport_provider(
    netlayer: ?*PancakeOnionNetlayer,
    out_provider: ?*c.PancakeTransportProvider,
) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return c.PANCAKE_ERR_NULL_POINTER;
    const slot = out_provider orelse return c.PANCAKE_ERR_NULL_POINTER;
    slot.* = provider.package(payload);
    return c.PANCAKE_OK;
}

pub export fn pancake_onion_netlayer_shutdown(netlayer: ?*PancakeOnionNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    payload.shutdown();
}

fn releaseNetlayer(netlayer: ?*PancakeOnionNetlayer) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return c.PANCAKE_OK;
    if (payload.release()) |failure| {
        c.setLastErrorChain("onion netlayer release", failure);
        return failure_projection.providerListen(failure.cause);
    }
    return c.PANCAKE_OK;
}

pub export fn pancake_onion_netlayer_release(
    netlayer: ?*PancakeOnionNetlayer,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len))
        return c.PANCAKE_ERR_NULL_POINTER;
    return c.captureCallError(
        releaseNetlayer(netlayer),
        out_error,
        error_cap,
        out_error_len,
    );
}

// The façade exports the symbols; the framed owner supplies their complete
// implementation. These are deliberately mechanical projections.
pub export fn pancake_onion_connect(
    netlayer: ?*PancakeOnionNetlayer,
    service_id: ?[*]const u8,
    service_id_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.connect(
        netlayer,
        service_id,
        service_id_len,
        codec,
        max_frame_bytes,
        out_conn,
        out_error,
        error_cap,
        out_error_len,
    );
}

pub export fn pancake_onion_listen(
    netlayer: ?*PancakeOnionNetlayer,
    out_service_id: ?[*]u8,
    service_id_cap: usize,
    out_service_id_len: ?*usize,
    out_service_key: ?[*]u8,
    service_key_cap: usize,
    out_service_key_len: ?*usize,
    out_listener: ?*?*PancakeOnionListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.listen(
        netlayer,
        out_service_id,
        service_id_cap,
        out_service_id_len,
        out_service_key,
        service_key_cap,
        out_service_key_len,
        out_listener,
        out_error,
        error_cap,
        out_error_len,
    );
}

pub export fn pancake_onion_accept(
    listener: ?*PancakeOnionListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.accept(
        listener,
        codec,
        max_frame_bytes,
        out_conn,
        out_error,
        error_cap,
        out_error_len,
    );
}

pub export fn pancake_onion_listener_wait(
    listener: ?*PancakeOnionListener,
    timeout_ms: i32,
    out_ready: ?*u32,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.listenerWait(
        listener,
        timeout_ms,
        out_ready,
        out_error,
        error_cap,
        out_error_len,
    );
}

pub export fn pancake_onion_listener_readiness_fd(
    listener: ?*PancakeOnionListener,
    out_fd: ?*i32,
) i32 {
    c.lastErrorClear();
    return framed.listenerReadinessFd(listener, out_fd);
}

pub export fn pancake_onion_conn_readiness_fd(
    conn: ?*PancakeOnionConn,
    out_fd: ?*i32,
) i32 {
    c.lastErrorClear();
    return framed.connReadinessFd(conn, out_fd);
}

pub export fn pancake_onion_conn_read_frame(
    conn: ?*PancakeOnionConn,
    out_frame: ?*c.PancakeManagedFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.connReadFrame(
        conn,
        out_frame,
        out_error,
        error_cap,
        out_error_len,
    );
}

pub export fn pancake_onion_conn_write_frame(
    conn: ?*PancakeOnionConn,
    frame: ?*const c.PancakeFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.connWriteFrame(
        conn,
        frame,
        out_error,
        error_cap,
        out_error_len,
    );
}

pub export fn pancake_onion_conn_shutdown(conn: ?*PancakeOnionConn) i32 {
    c.lastErrorClear();
    return framed.connShutdown(conn);
}

pub export fn pancake_onion_conn_release(
    conn: ?*PancakeOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.connRelease(conn, out_error, error_cap, out_error_len);
}

pub export fn pancake_onion_listener_shutdown(listener: ?*PancakeOnionListener) void {
    framed.listenerShutdown(listener);
}

pub export fn pancake_onion_listener_release(
    listener: ?*PancakeOnionListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.listenerRelease(
        listener,
        out_error,
        error_cap,
        out_error_len,
    );
}

fn netlayerFromOpaque(netlayer: ?*PancakeOnionNetlayer) ?*runtime.Netlayer {
    return @ptrCast(@alignCast(netlayer orelse return null));
}
