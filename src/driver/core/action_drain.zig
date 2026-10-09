//! Shared host-action drain: one `while (takeAction) switch` over every arm,
//! with per-embedder behavior injected through a comptime executor.
//! `driver.HostRuntime` rides it and supplies only the arms that differ by
//! embedder; `need_gift_id` lives here so a new action kind is a compile
//! error in every embedder, not a silent miss in a hand-rolled copy.

const Host = @import("host.zig").Host;
const host_action = @import("host/action.zig");

/// Why an embedder-facing drain returned. A finite Host quantum deliberately
/// returns `.yielded` before asking the core for another slice; explicitly
/// blocking fronts may continue immediately. Outbound pressure instead needs
/// transport progress, so every embedder must return to its readiness driver.
pub const DrainResult = enum { drained, yielded, outbound_blocked };

/// Drain every queued `HostAction` through `exec`.
///
/// `io` must provide `randomSecure(buf: []u8) !void` — the entropy boundary
/// for gift-id draws. `exec` must provide:
/// - `flush(peer_handle: engine.PeerHandle) !void`
/// - `close(peer_handle: engine.PeerHandle) !void`
/// - `dial(d: HostAction.dial) !void` — exact ticket and route; project its
///   view via `pendingDial`.
///   On failure it must have published no external connection, or must have
///   rolled that connection back before returning: the ticket is requeued.
/// - `cancelDial(d: HostAction.cancel_dial) !void` — interrupt and join the
///   external effect, then acknowledge it through `Host.dialCancelled`.
/// - optionally, `prepare(action: HostAction) !void` — acquire adapter-owned
///   publication capacity while the action is still parked and unconsumed.
/// - `complete(action: HostAction) !void` — owns `.settled` / `.failed` (adopt
///   or `host.freeAction`; the skeleton does not free them)
pub fn drainActions(host: *Host, io: anytype, exec: anytype) !DrainResult {
    // A new pass is the pressure-yield boundary: the embedder ran its reactor
    // since the last one, so a previously refused resume pump gets one fresh
    // bounded attempt (see `Host.resume_pump_refused`).
    host.resume_pump_refused = false;
    while (try host.peekAction()) |next| {
        // Entropy is the one fallible preparation this shared executor owns.
        // Draw it while the action is still parked; a transient source failure
        // must not consume the only ticket that can finish the handoff.
        var gift_id: [32]u8 = undefined;
        if (next == .need_gift_id) try io.randomSecure(&gift_id);
        if (@hasDecl(@TypeOf(exec), "prepare")) try exec.prepare(next);

        const action = (try host.takeAction()) orelse unreachable;
        switch (action) {
            .flush => |peer_handle| try exec.flush(peer_handle),
            .close => |peer_handle| try exec.close(peer_handle),
            .need_gift_id => |n| {
                host.provideGiftId(n.ticket, &gift_id) catch |err| {
                    host_action.retryEffect(host, action);
                    return err;
                };
            },
            .dial => |d| exec.dial(d) catch |err| {
                host_action.retryEffect(host, action);
                return err;
            },
            .cancel_dial => |d| exec.cancelDial(d) catch |err| {
                host_action.retryEffect(host, action);
                return err;
            },
            .settled, .failed => try exec.complete(action),
            // This is a scheduling boundary, not an I/O arm. Return before
            // asking the Host for another finite slice so a reactor-backed
            // embedder can give its other ready work a turn.
            .resume_work => return if (host.resume_pump_refused)
                .outbound_blocked
            else
                .yielded,
        }
    }
    return .drained;
}
