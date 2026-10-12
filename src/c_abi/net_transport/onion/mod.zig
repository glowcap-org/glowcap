//! Stable C facade for the native onion provider archive.
//!
//! The facade owns opaque-handle validation, construction, teardown, and the
//! fixed C surface. `provider/` projects the generic stream-provider contract.
//! `framed/` projects blocking managed-frame handles. Tor control, SOCKS, onion
//! service lifecycle, and socket policy remain in `net.onion`.

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");
const c = @import("c_abi_shared");
const contract = @import("contract.zig");
const create_runtime = @import("runtime/create.zig");
const runtime = @import("runtime/state.zig");
const provider = @import("provider/mod.zig");
const framed = @import("framed/mod.zig");
const failure_projection = @import("failure.zig");

pub const GlowcapOnionNetlayer = contract.GlowcapOnionNetlayer;
pub const GlowcapOnionConn = contract.GlowcapOnionConn;
pub const GlowcapOnionListener = contract.GlowcapOnionListener;
pub const GlowcapOnionConfig = contract.GlowcapOnionConfig;
pub const contract_layouts = [_]c.archive_contract.Layout{
    c.archive_contract.layout("GLOWCAP_ONION_CONFIG", GlowcapOnionConfig),
};
pub const GLOWCAP_ONION_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "onion",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);
pub const GLOWCAP_ONION_AUTH_NONE = contract.GLOWCAP_ONION_AUTH_NONE;
pub const GLOWCAP_ONION_AUTH_COOKIE = contract.GLOWCAP_ONION_AUTH_COOKIE;
pub const GLOWCAP_ONION_AUTH_PASSWORD = contract.GLOWCAP_ONION_AUTH_PASSWORD;
pub const GLOWCAP_ONION_SERVICE_ID_LEN = contract.GLOWCAP_ONION_SERVICE_ID_LEN;
pub const GLOWCAP_ONION_SERVICE_KEY_CAP = contract.GLOWCAP_ONION_SERVICE_KEY_CAP;

const GlowcapContext = c.GlowcapContext;
pub const symbols = @import("symbols.zig");

pub export fn glowcap_onion_archive_fingerprint() u64 {
    return GLOWCAP_ONION_ARCHIVE_FINGERPRINT;
}

pub export fn glowcap_onion_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

pub export fn glowcap_onion_clear_last_error() void {
    c.lastErrorClear();
}

pub export fn glowcap_onion_netlayer_new(
    config: ?*const GlowcapOnionConfig,
    out_netlayer: ?*?*GlowcapOnionNetlayer,
) i32 {
    c.lastErrorClear();
    const slot = out_netlayer orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const value = config orelse return c.GLOWCAP_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, value, slot);
}

pub export fn glowcap_onion_netlayer_new_in(
    context: ?*GlowcapContext,
    config: ?*const GlowcapOnionConfig,
    out_netlayer: ?*?*GlowcapOnionNetlayer,
) i32 {
    c.lastErrorClear();
    const c_context = c.ctxFromOpaque(context) orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const value = config orelse return c.GLOWCAP_ERR_NULL_POINTER;
    return netlayerNewIn(c_context.allocator(), value, slot);
}

fn netlayerNewIn(
    allocator: std.mem.Allocator,
    config: *const GlowcapOnionConfig,
    out: *?*GlowcapOnionNetlayer,
) i32 {
    var payload: ?*runtime.Netlayer = null;
    const result = create_runtime.create(allocator, config, &payload);
    out.* = if (payload) |value| @ptrCast(value) else null;
    return result;
}

pub export fn glowcap_onion_transport_provider(
    netlayer: ?*GlowcapOnionNetlayer,
    out_provider: ?*c.GlowcapTransportProvider,
) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_provider orelse return c.GLOWCAP_ERR_NULL_POINTER;
    slot.* = provider.package(payload);
    return c.GLOWCAP_OK;
}

pub export fn glowcap_onion_netlayer_shutdown(netlayer: ?*GlowcapOnionNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    payload.shutdown();
}

fn releaseNetlayer(netlayer: ?*GlowcapOnionNetlayer) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return c.GLOWCAP_OK;
    if (payload.release()) |failure| {
        c.setLastErrorChain("onion netlayer release", failure);
        return failure_projection.providerListen(failure.cause);
    }
    return c.GLOWCAP_OK;
}

pub export fn glowcap_onion_netlayer_release(
    netlayer: ?*GlowcapOnionNetlayer,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len))
        return c.GLOWCAP_ERR_NULL_POINTER;
    return c.captureCallError(
        releaseNetlayer(netlayer),
        out_error,
        error_cap,
        out_error_len,
    );
}

// The facade exports the symbols. The framed owner supplies their
// implementation, so these are mechanical projections.
pub export fn glowcap_onion_connect(
    netlayer: ?*GlowcapOnionNetlayer,
    service_id: ?[*]const u8,
    service_id_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapOnionConn,
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

pub export fn glowcap_onion_listen(
    netlayer: ?*GlowcapOnionNetlayer,
    out_service_id: ?[*]u8,
    service_id_cap: usize,
    out_service_id_len: ?*usize,
    out_service_key: ?[*]u8,
    service_key_cap: usize,
    out_service_key_len: ?*usize,
    out_listener: ?*?*GlowcapOnionListener,
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

pub export fn glowcap_onion_accept(
    listener: ?*GlowcapOnionListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapOnionConn,
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

pub export fn glowcap_onion_listener_wait(
    listener: ?*GlowcapOnionListener,
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

pub export fn glowcap_onion_listener_readiness_fd(
    listener: ?*GlowcapOnionListener,
    out_fd: ?*i32,
) i32 {
    c.lastErrorClear();
    return framed.listenerReadinessFd(listener, out_fd);
}

pub export fn glowcap_onion_conn_readiness_fd(
    conn: ?*GlowcapOnionConn,
    out_fd: ?*i32,
) i32 {
    c.lastErrorClear();
    return framed.connReadinessFd(conn, out_fd);
}

pub export fn glowcap_onion_conn_read_frame(
    conn: ?*GlowcapOnionConn,
    out_frame: ?*c.GlowcapManagedFrame,
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

pub export fn glowcap_onion_conn_write_frame(
    conn: ?*GlowcapOnionConn,
    frame: ?*const c.GlowcapFrame,
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

pub export fn glowcap_onion_conn_shutdown(conn: ?*GlowcapOnionConn) i32 {
    c.lastErrorClear();
    return framed.connShutdown(conn);
}

pub export fn glowcap_onion_conn_release(
    conn: ?*GlowcapOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    return framed.connRelease(conn, out_error, error_cap, out_error_len);
}

pub export fn glowcap_onion_listener_shutdown(listener: ?*GlowcapOnionListener) void {
    framed.listenerShutdown(listener);
}

pub export fn glowcap_onion_listener_release(
    listener: ?*GlowcapOnionListener,
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

fn netlayerFromOpaque(netlayer: ?*GlowcapOnionNetlayer) ?*runtime.Netlayer {
    return @ptrCast(@alignCast(netlayer orelse return null));
}
