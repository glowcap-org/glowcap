//! Shared host-action drain: one `while (takeAction) switch` over the six
//! arms, with per-embedder behavior injected through a comptime executor.
//! `Bridge` (and any future Zig embedder) supply the arms that differ;
//! `need_gift_id` lives here so a seventh action kind is a compile error in
//! every embedder, not a silent miss in one of N hand-rolled copies.

const Host = @import("host.zig").Host;

/// Drain every queued `HostAction` through `exec`.
///
/// `io` must provide `randomSecure(buf: []u8) !void` — the entropy boundary
/// for gift-id draws. `exec` must provide:
/// - `flush(peer_id: engine.PeerId) !void`
/// - `close(peer_id: engine.PeerId) !void`
/// - `dial(d: HostAction.dial) !void` — ticket only; view via `pendingDial`
/// - `complete(action: HostAction) !void` — owns `.settled` / `.failed` (adopt
///   or `host.freeAction`; the skeleton does not free them)
pub fn drainActions(host: *Host, io: anytype, exec: anytype) !void {
    while (try host.takeAction()) |action| {
        switch (action) {
            .flush => |peer_id| try exec.flush(peer_id),
            .close => |peer_id| try exec.close(peer_id),
            .need_gift_id => |n| {
                var gift_id: [32]u8 = undefined;
                try io.randomSecure(&gift_id);
                try host.provideGiftId(n.ticket, &gift_id);
            },
            .dial => |d| try exec.dial(d),
            .settled, .failed => try exec.complete(action),
        }
    }
}
