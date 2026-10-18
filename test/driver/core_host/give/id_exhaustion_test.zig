//! An inline give whose promise id space is spent refuses before it retains a
//! capability, stores a promise row, or stages a redemption, and spends no id.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const support = @import("../../../support/core_host.zig");
const signedGive = @import("../../../engine/node/harness.zig").testGiveBytes;
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

test "core host: an inline give refuses an exhausted promise id space without effect" {
    var host = support.init(a, @splat(0xc1), Host.Options.withFrameCap(h.frame_cap));
    defer host.deinit();
    var partner = support.init(a, @splat(0xc2), Host.Options.withFrameCap(h.frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| a.free(dial.designator);
        dials.deinit(a);
    }
    const pair = try h.openPair(a, &host, &partner, "127.0.0.1:7981", &dials);

    const bytes = try signedGive(a);
    defer a.free(bytes);
    const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(a, bytes);
    defer model.freeHandoffGive(a, give);

    host.capability_promise_ids.next = std.math.maxInt(u64);
    const capabilities_before = host.capabilities.liveCount();
    try std.testing.expectError(error.CapabilitySpaceExhausted, host.acceptInlineGive(pair.a, give));
    try std.testing.expectEqual(@as(usize, 0), host.capability_promises.count());
    try std.testing.expectEqual(capabilities_before, host.capabilities.liveCount());
    try std.testing.expectEqual(std.math.maxInt(u64), host.capability_promise_ids.next);
    while (try host.nextAction()) |action| switch (action) {
        .dial => return error.UnexpectedDial,
        else => {},
    };
}
