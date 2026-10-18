//! A deferred tell owns work on its source session until dispatch or failure.
//! The signed fixture gives stop at dial failure or introducer closure, so
//! these tests never reach exporter withdrawal or transport authentication.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const support = @import("../../../support/core_host.zig");
const signedGive = @import("../../../engine/node/harness.zig").testGiveBytes;
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

test "core host: broken deferred tell retires a finishing source distinct from its introducer" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
            for ([_]bool{ false, true }) |close_introducer| {
                for ([_]bool{ false, true }) |abandon| {
                    var failing = std.testing.FailingAllocator.init(a, .{});
                    var options = Host.Options.withFrameCap(h.frame_cap);
                    options.captp_version = profile;
                    options.codec = codec;
                    options.features = model.FeatureSet.full().forCaptpVersion(profile);
                    var host = support.init(failing.allocator(), @splat(0x91), options);
                    defer host.deinit();
                    var introducer = support.init(a, @splat(0x92), options);
                    defer introducer.deinit();
                    var source = support.init(a, @splat(0x93), options);
                    defer source.deinit();
                    var dials: std.ArrayList(h.ParkedDial) = .empty;
                    defer {
                        for (dials.items) |dial| a.free(dial.designator);
                        dials.deinit(a);
                    }
                    const intro_pair = try h.openPair(a, &host, &introducer, "127.0.0.1:7951", &dials);
                    const source_pair = try h.openPair(a, &host, &source, "127.0.0.1:7952", &dials);
                    const bytes = try signedGive(a);
                    defer a.free(bytes);
                    const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(a, bytes);
                    defer model.freeHandoffGive(a, give);
                    const promise = try host.acceptInlineGive(intro_pair.a, give);
                    const dial = (try host.nextAction()).?.dial;
                    const argument = try host.spawn(source_pair.a, h.Widget, .{});
                    var arena = std.heap.ArenaAllocator.init(a);
                    defer arena.deinit();
                    try host.tellValues(source_pair.a, promise, "poke", &.{.{ .capability = argument }}, arena.allocator());
                    try host.releaseCapability(argument, 1);
                    try std.testing.expect(host.localActorFor(argument) != null);
                    try std.testing.expectEqual(@as(u24, 1), source_pair.a.pendingOperations());
                    try host.beginSessionClose(source_pair.a, .{ .finish = .unbounded }, 0);
                    try std.testing.expectEqual(.finishing, source_pair.a.lifecyclePhase());
                    if (abandon) try host.releaseCapability(promise, 1);
                    // Failure must retire the tell without needing allocation.
                    failing.fail_index = failing.alloc_index;
                    if (close_introducer) try host.releaseSession(intro_pair.a) else try host.dialFailed(dial.ticket, dial.route_index, "unavailable");
                    failing.fail_index = std.math.maxInt(usize);
                    try std.testing.expectEqual(@as(u24, 0), source_pair.a.pendingOperations());
                    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
                    try std.testing.expect(host.localActorFor(argument) == null);
                    while (try host.nextAction()) |action| {
                        // A live dial remains Host work after introducer death
                        // until its executor reports a terminal outcome.
                        if (action == .cancel_dial) try host.dialCancelled(action.cancel_dial.ticket, action.cancel_dial.route_index);
                    }
                    try std.testing.expectEqual(.terminating, source_pair.a.lifecyclePhase());
                    if (!abandon) try host.releaseCapability(promise, 1);
                    try std.testing.expectEqual(@as(usize, 0), host.capability_promises.count());
                    if (close_introducer) try host.dialFailed(dial.ticket, dial.route_index, "unavailable");
                    try std.testing.expectEqual(@as(usize, 0), host.node.pendingDialCount());
                }
            }
        }
    }
}
