//! Shared C-ABI embedder pump helpers (ADR-0072 fifth amendment).
//!
//! Authority for the one-loop drain over `pancake_host_next_action`: Zig tests
//! (and later an optional C convenience wrapper) call this instead of
//! hand-rolling the switch. The pull-queue remains the normative C contract —
//! these helpers *use* `pancake_host_next_action`; they do not replace it with
//! a callback-vtable primary seam.
//!
//! No `export fn` here. A future C wrapper, if landed, lives beside the other
//! `pancake_host_*` exports in `mod.zig` and calls into this module.

/// Drain every queued action on `host` through `exec`.
///
/// `Driver` is the `c_abi_driver` module (hosts, action kinds, `pancake_host_*`).
/// `Codes` is the shared vocabulary module that names `PANCAKE_OK` /
/// `PANCAKE_ERR_WOULD_BLOCK` (typically `c_abi`).
///
/// Each `exec` arm returns `bool`: `true` when the arm counts as progress for a
/// quiescence pump (gift-id answered, dial parked, settle routed). A FLUSH /
/// CLOSE that only notices "write when ready" may return `false` when a sibling
/// shuttle already polls outbound — matching the one-loop rule without
/// spinning on empty flush notices.
///
/// `exec` must provide:
/// - `flush(host, action) !bool`
/// - `close(host, action) !bool`
/// - `needGiftId(host, action) !bool`
/// - `complete(host, action) !bool` — owns SETTLE / FAIL
/// - `dial(host, action) !bool`
///
/// Returns `true` when any arm reported progress.
pub fn drainHost(comptime Driver: type, comptime Codes: type, host: ?*Driver.PancakeHost, exec: anytype) !bool {
    var acted = false;
    while (true) {
        var action: Driver.PancakeHostAction = undefined;
        const rc = Driver.pancake_host_next_action(host, &action);
        if (rc == Codes.PANCAKE_ERR_WOULD_BLOCK) break;
        if (rc != Codes.PANCAKE_OK) return error.HostActionFailed;
        const progressed = switch (action.kind) {
            Driver.PANCAKE_HOST_ACTION_FLUSH => try exec.flush(host, &action),
            Driver.PANCAKE_HOST_ACTION_CLOSE => try exec.close(host, &action),
            Driver.PANCAKE_HOST_ACTION_NEED_GIFT_ID => try exec.needGiftId(host, &action),
            Driver.PANCAKE_HOST_ACTION_SETTLE, Driver.PANCAKE_HOST_ACTION_FAIL => try exec.complete(host, &action),
            Driver.PANCAKE_HOST_ACTION_DIAL => try exec.dial(host, &action),
            else => return error.UnknownHostAction,
        };
        if (progressed) acted = true;
    }
    return acted;
}

/// Drain every host in `hosts` through the same `exec`. Returns `true` when
/// any arm reported progress.
pub fn drainHosts(comptime Driver: type, comptime Codes: type, hosts: []const ?*Driver.PancakeHost, exec: anytype) !bool {
    var acted = false;
    for (hosts) |host| {
        if (try drainHost(Driver, Codes, host, exec)) acted = true;
    }
    return acted;
}
