//! Inline gives a session delivers are held to its `max_pending_withdraws`:
//! one past the cap is refused before it retains a capability or stores a
//! row, and a settled redemption frees its seat.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const support = @import("../../../support/core_host.zig");
const signedGive = @import("../../../engine/node/harness.zig").testGiveBytes;
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

test "core host: inline gives past the session's pending-withdraw cap are refused until one settles" {
    var options = Host.Options.withFrameCap(h.frame_cap);
    options.limits.max_pending_withdraws = 2;
    var host = support.init(a, @splat(0xc3), options);
    defer host.deinit();
    var partner = support.init(a, @splat(0xc4), Host.Options.withFrameCap(h.frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| a.free(dial.designator);
        dials.deinit(a);
    }
    const pair = try h.openPair(a, &host, &partner, "127.0.0.1:7982", &dials);

    const bytes = try signedGive(a);
    defer a.free(bytes);
    const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(a, bytes);
    defer model.freeHandoffGive(a, give);

    const first = try host.acceptInlineGive(pair.a, give);
    const second = try host.acceptInlineGive(pair.a, give);
    try std.testing.expectEqual(@as(?u32, 2), host.pending_inline_gives.get(pair.a.peer_handle));
    const capabilities_before = host.capabilities.liveCount();
    try std.testing.expectError(error.PendingWithdrawCapExceeded, host.acceptInlineGive(pair.a, give));
    try std.testing.expectEqual(@as(usize, 2), host.capability_promises.count());
    try std.testing.expectEqual(capabilities_before, host.capabilities.liveCount());

    // Both gives name one exporter, so one dial carries them. Its failure
    // settles both rows, and the session's seats come back.
    var ticket: ?glowcap.ocapn.engine.Node.PendingId = null;
    while (try host.nextAction()) |action| switch (action) {
        .dial => |dial| ticket = dial.ticket,
        else => {},
    };
    try host.dialFailed(ticket orelse return error.MissingDial, 0, "exporter unavailable");
    try std.testing.expectEqual(@as(?u32, null), host.pending_inline_gives.get(pair.a.peer_handle));
    const third = try host.acceptInlineGive(pair.a, give);
    try std.testing.expectEqual(@as(?u32, 1), host.pending_inline_gives.get(pair.a.peer_handle));

    try host.releaseCapability(first, 1);
    try host.releaseCapability(second, 1);
    try host.releaseCapability(third, 1);
}
