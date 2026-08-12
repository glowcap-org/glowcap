//! Shared host-action drain: one `while (takeAction) switch` over the seven
//! arms, with per-embedder behavior injected through a comptime executor.
//! Both Zig embedders ride it — `driver.Bridge` at the loop tier and the
//! owning `driver.HostRuntime` face at the blocking tier (ADR-0090) — supplying only
//! the arms that differ; `need_gift_id` lives here so a new action kind is a
//! compile error in every embedder, not a silent miss in one of N
//! hand-rolled copies.

const Host = @import("host.zig").Host;
const host_action = @import("host_action.zig");

/// Why an embedder-facing drain returned. A finite Host quantum deliberately
/// returns `.yielded` before asking the core for another slice; reactor-backed
/// embedders reschedule it, while explicitly blocking fronts may loop.
pub const DrainResult = enum { drained, yielded };

/// Drain every queued `HostAction` through `exec`.
///
/// `io` must provide `randomSecure(buf: []u8) !void` — the entropy boundary
/// for gift-id draws. `exec` must provide:
/// - `flush(peer_id: engine.PeerId) !void`
/// - `close(peer_id: engine.PeerId) !void`
/// - `dial(d: HostAction.dial) !void` — ticket only; view via `pendingDial`.
///   On failure it must have published no external connection, or must have
///   rolled that connection back before returning: the ticket is requeued.
/// - `complete(action: HostAction) !void` — owns `.settled` / `.failed` (adopt
///   or `host.freeAction`; the skeleton does not free them)
pub fn drainActions(host: *Host, io: anytype, exec: anytype) !DrainResult {
    while (try host.peekAction()) |next| {
        // Entropy is the one fallible preparation this shared executor owns.
        // Draw it while the action is still parked; a transient source failure
        // must not consume the only ticket that can finish the handoff.
        var gift_id: [32]u8 = undefined;
        if (next == .need_gift_id) try io.randomSecure(&gift_id);

        const action = (try host.takeAction()) orelse unreachable;
        switch (action) {
            .flush => |peer_id| try exec.flush(peer_id),
            .close => |peer_id| try exec.close(peer_id),
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
            .settled, .failed => try exec.complete(action),
            // This is a scheduling boundary, not an I/O arm. Return before
            // asking the Host for another finite slice so a reactor-backed
            // embedder can give its other ready work a turn.
            .resume_work => return .yielded,
        }
    }
    return .drained;
}
