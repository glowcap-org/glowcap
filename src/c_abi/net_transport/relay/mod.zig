//! Stable C facade for the relay provider archive.
//!
//! The facade validates opaque handles, projects construction and teardown,
//! and exposes the generic transport-provider table. Readiness, cancellation,
//! and connection/listener lifecycle belong to `runtime/`. Relay carrier,
//! WebSocket, routing, and TLS policy belong to `net.relay`.

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");

const c = @import("c_abi_shared");
const contract = @import("contract.zig");
const failure_projection = @import("failure/projection.zig");
const net = @import("net");
const runtime = @import("runtime/mod.zig");

pub const GlowcapRelayRuntime = opaque {};
const GlowcapContext = c.GlowcapContext;
const Payload = runtime.Payload;

pub const symbols = @import("symbols.zig");

pub const GlowcapRelayConfig = contract.GlowcapRelayConfig;
pub const contract_layouts = [_]c.archive_contract.Layout{
    c.archive_contract.layout("GLOWCAP_RELAY_CONFIG", GlowcapRelayConfig),
};
pub const GLOWCAP_RELAY_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "relay",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);
pub const GLOWCAP_RELAY_CONFIG_ABI_VERSION = contract.GLOWCAP_RELAY_CONFIG_ABI_VERSION;
pub const GLOWCAP_RELAY_TRUST_SYSTEM = contract.GLOWCAP_RELAY_TRUST_SYSTEM;
pub const GLOWCAP_RELAY_TRUST_COPIED_PEM = contract.GLOWCAP_RELAY_TRUST_COPIED_PEM;
pub const GLOWCAP_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES = net.relay.max_rendezvous_relay_hint_bytes;

pub export fn glowcap_relay_archive_fingerprint() u64 {
    return GLOWCAP_RELAY_ARCHIVE_FINGERPRINT;
}

fn payloadFromOpaque(value: ?*GlowcapRelayRuntime) ?*Payload {
    return @ptrCast(@alignCast(value orelse return null));
}

pub export fn glowcap_relay_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

pub export fn glowcap_relay_clear_last_error() void {
    c.lastErrorClear();
}

pub export fn glowcap_relay_runtime_new(
    config: ?*const GlowcapRelayConfig,
    out_runtime: ?*?*GlowcapRelayRuntime,
) i32 {
    c.lastErrorClear();
    const slot = out_runtime orelse return c.GLOWCAP_ERR_NULL_POINTER;
    return runtimeNewIn(c.library_allocator, config, slot);
}

pub export fn glowcap_relay_runtime_new_in(
    context: ?*GlowcapContext,
    config: ?*const GlowcapRelayConfig,
    out_runtime: ?*?*GlowcapRelayRuntime,
) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_runtime orelse return c.GLOWCAP_ERR_NULL_POINTER;
    return runtimeNewIn(c_ctx.allocator(), config, slot);
}

fn runtimeNewIn(
    allocator: std.mem.Allocator,
    config: ?*const GlowcapRelayConfig,
    slot: *?*GlowcapRelayRuntime,
) i32 {
    var payload: ?*Payload = null;
    const result = runtime.create(allocator, config, &payload);
    slot.* = if (payload) |value| @ptrCast(value) else null;
    return result;
}

pub export fn glowcap_relay_transport_provider(
    relay_runtime: ?*GlowcapRelayRuntime,
    out_provider: ?*c.GlowcapTransportProvider,
) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(relay_runtime) orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_provider orelse return c.GLOWCAP_ERR_NULL_POINTER;
    slot.* = payload.transportProvider();
    return c.GLOWCAP_OK;
}

fn releaseRuntime(relay_runtime: ?*GlowcapRelayRuntime) i32 {
    const payload = payloadFromOpaque(relay_runtime) orelse return c.GLOWCAP_OK;
    if (payload.release()) |failure| {
        c.setLastErrorChain("relay runtime release", failure);
        return failure_projection.release(failure.cause);
    }
    return c.GLOWCAP_OK;
}

pub export fn glowcap_relay_runtime_release(
    relay_runtime: ?*GlowcapRelayRuntime,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return c.GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        releaseRuntime(relay_runtime),
        out_error,
        error_cap,
        out_error_len,
    );
}
