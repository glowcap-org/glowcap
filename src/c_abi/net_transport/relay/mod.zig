//! Stable C facade for the native relay provider archive.
//!
//! The facade validates opaque handles, projects construction and teardown,
//! and exposes the generic transport-provider table. Readiness, cancellation,
//! and connection/listener lifecycle belong to `runtime/`; relay carrier,
//! WebSocket, routing, and TLS policy belong to `net.relay`.

const std = @import("std");

const c = @import("c_abi_shared");
const contract = @import("contract.zig");
const failure_projection = @import("failure/projection.zig");
const net = @import("net");
const runtime = @import("runtime/mod.zig");

pub const PancakeRelayRuntime = opaque {};
const PancakeContext = c.PancakeContext;
const Payload = runtime.Payload;

pub const symbols = @import("symbols.zig");

pub const PancakeRelayConfig = contract.PancakeRelayConfig;
pub const PancakeRelayTrustSummary = contract.PancakeRelayTrustSummary;
pub const contract_layouts = [_]c.archive_contract.Layout{
    c.archive_contract.layout("PANCAKE_RELAY_CONFIG", PancakeRelayConfig),
    c.archive_contract.layout("PANCAKE_RELAY_TRUST_SUMMARY", PancakeRelayTrustSummary),
};
pub const PANCAKE_RELAY_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "relay",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);
pub const PANCAKE_RELAY_CONFIG_ABI_VERSION = contract.PANCAKE_RELAY_CONFIG_ABI_VERSION;
pub const PANCAKE_RELAY_TRUST_SYSTEM = contract.PANCAKE_RELAY_TRUST_SYSTEM;
pub const PANCAKE_RELAY_TRUST_COPIED_PEM = contract.PANCAKE_RELAY_TRUST_COPIED_PEM;
pub const PANCAKE_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES = net.relay.max_rendezvous_relay_hint_bytes;

pub export fn pancake_relay_archive_fingerprint() u64 {
    return PANCAKE_RELAY_ARCHIVE_FINGERPRINT;
}

fn payloadFromOpaque(value: ?*PancakeRelayRuntime) ?*Payload {
    return @ptrCast(@alignCast(value orelse return null));
}

pub export fn pancake_relay_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

pub export fn pancake_relay_clear_last_error() void {
    c.lastErrorClear();
}

pub export fn pancake_relay_runtime_new(
    config: ?*const PancakeRelayConfig,
    out_runtime: ?*?*PancakeRelayRuntime,
) i32 {
    c.lastErrorClear();
    const slot = out_runtime orelse return c.PANCAKE_ERR_NULL_POINTER;
    return runtimeNewIn(c.library_allocator, config, slot);
}

pub export fn pancake_relay_runtime_new_in(
    context: ?*PancakeContext,
    config: ?*const PancakeRelayConfig,
    out_runtime: ?*?*PancakeRelayRuntime,
) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return c.PANCAKE_ERR_NULL_POINTER;
    const slot = out_runtime orelse return c.PANCAKE_ERR_NULL_POINTER;
    return runtimeNewIn(c_ctx.allocator(), config, slot);
}

fn runtimeNewIn(
    allocator: std.mem.Allocator,
    config: ?*const PancakeRelayConfig,
    slot: *?*PancakeRelayRuntime,
) i32 {
    var payload: ?*Payload = null;
    const result = runtime.create(allocator, config, &payload);
    slot.* = if (payload) |value| @ptrCast(value) else null;
    return result;
}

pub export fn pancake_relay_transport_provider(
    relay_runtime: ?*PancakeRelayRuntime,
    out_provider: ?*c.PancakeTransportProvider,
) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(relay_runtime) orelse return c.PANCAKE_ERR_NULL_POINTER;
    const slot = out_provider orelse return c.PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.transportProvider();
    return c.PANCAKE_OK;
}

pub export fn pancake_relay_runtime_trust_summary(
    relay_runtime: ?*PancakeRelayRuntime,
    out_summary: ?*PancakeRelayTrustSummary,
) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(relay_runtime) orelse return c.PANCAKE_ERR_NULL_POINTER;
    const slot = out_summary orelse return c.PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.trustSummary();
    return c.PANCAKE_OK;
}

fn releaseRuntime(relay_runtime: ?*PancakeRelayRuntime) i32 {
    const payload = payloadFromOpaque(relay_runtime) orelse return c.PANCAKE_OK;
    if (payload.release()) |failure| {
        c.setLastErrorChain("relay runtime release", failure);
        return failure_projection.release(failure.cause);
    }
    return c.PANCAKE_OK;
}

pub export fn pancake_relay_runtime_release(
    relay_runtime: ?*PancakeRelayRuntime,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return c.PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        releaseRuntime(relay_runtime),
        out_error,
        error_cap,
        out_error_len,
    );
}
