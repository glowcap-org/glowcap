//! Shared C-ABI embedder pump helpers (ADR-0022).
//!
//! Authority for the one-loop drain over `glowcap_host_next_action`: Zig tests
//! and `glowcap_host_pump_drain` call this instead of hand-rolling the switch.
//! The pull-queue remains the normative C contract. These helpers *use*
//! `glowcap_host_next_action`. They do not replace it with a callback-vtable
//! primary seam. The kind inventory is locked to `driver_core.HostAction` at
//! comptime so a new Zig arm fails here until the C drain is updated.
//!
//! No `export fn` here. The C wrapper lives in `pump.zig`.

const std = @import("std");
const driver_core = @import("driver_core");

comptime {
    // Keep the C drain arm count lockstep with Zig HostAction.
    const tags = @typeInfo(driver_core.HostAction).@"union".field_names;
    if (tags.len != 8) {
        @compileError("embedder_pump: HostAction tag count changed — update drainHost switch");
    }
}

/// Drain every queued action on `host` through `exec`.
///
/// `Driver` is the `c_abi_host` module (hosts, action kinds, `glowcap_host_*`).
/// `Codes` is the shared vocabulary module that names `GLOWCAP_OK` /
/// `GLOWCAP_ERR_WOULD_BLOCK` (typically `c_abi`).
///
/// Each `exec` arm returns `bool`: `true` when the arm counts as progress for a
/// quiescence pump (gift-id answered, dial parked, settle routed). A FLUSH /
/// CLOSE that only notices "write when ready" may return `false` when a sibling
/// shuttle already polls outbound, matching the one-loop rule without
/// spinning on empty flush notices.
///
/// `exec` must provide:
/// - `flush(host, action) !bool`
/// - `close(host, action) !bool`
/// - `needGiftId(host, action) !bool`
/// - `complete(host, action) !bool`: owns SETTLE / FAIL
/// - `dial(host, action) !bool`: DIAL and CANCEL_DIAL effects
///
pub const DrainResult = struct {
    acted: bool = false,
    yielded: bool = false,
};

/// Returns whether any arm reported progress and whether the finite Host
/// scheduler requested a new embedder turn. A yield is consumed but ends this
/// call. Asking the core for another slice here would defeat the scheduler
/// boundary the action represents.
pub fn drainHost(comptime Driver: type, comptime Codes: type, host: ?*Driver.GlowcapHost, exec: anytype) !DrainResult {
    var acted = false;
    while (true) {
        var action: Driver.GlowcapHostAction = undefined;
        const rc = Driver.glowcap_host_next_action(host, &action);
        if (rc == Codes.GLOWCAP_ERR_WOULD_BLOCK) break;
        if (rc != Codes.GLOWCAP_OK) return error.HostActionFailed;
        const progressed = switch (action.kind) {
            Driver.GLOWCAP_HOST_ACTION_FLUSH => try exec.flush(host, &action),
            Driver.GLOWCAP_HOST_ACTION_CLOSE => try exec.close(host, &action),
            Driver.GLOWCAP_HOST_ACTION_NEED_GIFT_ID => try exec.needGiftId(host, &action),
            Driver.GLOWCAP_HOST_ACTION_SETTLE, Driver.GLOWCAP_HOST_ACTION_FAIL => try exec.complete(host, &action),
            Driver.GLOWCAP_HOST_ACTION_DIAL => try exec.dial(host, &action),
            Driver.GLOWCAP_HOST_ACTION_CANCEL_DIAL => try exec.dial(host, &action),
            Driver.GLOWCAP_HOST_ACTION_RESUME => return .{ .acted = true, .yielded = true },
            else => return error.UnknownHostAction,
        };
        if (progressed) acted = true;
    }
    return .{ .acted = acted };
}

/// Give every host one drain turn through the same `exec`.
pub fn drainHosts(comptime Driver: type, comptime Codes: type, hosts: []const ?*Driver.GlowcapHost, exec: anytype) !DrainResult {
    var result: DrainResult = .{};
    for (hosts) |host| {
        const one = try drainHost(Driver, Codes, host, exec);
        result.acted = result.acted or one.acted;
        result.yielded = result.yielded or one.yielded;
    }
    return result;
}
