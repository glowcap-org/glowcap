//! Shared host-action drain: one `while (takeAction) switch` over the six
//! arms, with per-embedder behavior injected through a comptime executor.
//! `BlockingHost` and `LoopBridge` (and any future Zig embedder) supply the
//! arms that differ; `need_gift_id` and the dial-payload free live here so a
//! seventh action kind is a compile error in every embedder, not a silent miss
//! in one of N hand-rolled copies.

const Host = @import("host.zig").Host;

/// Drain every queued `HostAction` through `exec`.
///
/// `io` must provide `randomSecure(buf: []u8) !void` — the entropy boundary
/// for gift-id draws. `exec` must provide:
/// - `flush(conn_id: engine.ConnId) !void`
/// - `close(conn_id: engine.ConnId) !void`
/// - `dial(d: HostAction.Dial) !void` — dial payload is freed here after return
/// - `complete(action: HostAction) !void` — owns `.settled` / `.failed` (adopt
///   or `host.freeAction`; the skeleton does not free them)
pub fn drainActions(host: *Host, io: anytype, exec: anytype) !void {
    while (try host.takeAction()) |action| {
        switch (action) {
            .flush => |conn_id| try exec.flush(conn_id),
            .close => |conn_id| try exec.close(conn_id),
            .need_gift_id => |n| {
                var gift_id: [32]u8 = undefined;
                try io.randomSecure(&gift_id);
                try host.provideGiftId(n.ticket, &gift_id);
            },
            .dial => |d| {
                // The dial's payload is only borrowed by the executor; freed
                // here on every path once the dial has run.
                defer host.freeAction(.{ .dial = d });
                try exec.dial(d);
            },
            .settled, .failed => try exec.complete(action),
        }
    }
}
