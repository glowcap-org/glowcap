//! Releasing a queued promise send can publish wire GC for its last argument
//! retain. A break parked behind a recipient's outbound pressure returns to
//! the Node queue when that recipient's bytes are taken, so the next pump
//! retires every queued operation, including the one being released.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const support = @import("../../../support/core_host.zig");
const signedGive = @import("../../../engine/node/harness.zig").testGiveBytes;
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

test "core host: releasing a queued promise send survives its promise breaking in the release pump" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
            var options = Host.Options.withFrameCap(h.frame_cap);
            options.captp_version = profile;
            options.codec = codec;
            options.features = model.FeatureSet.full().forCaptpVersion(profile);
            var host = support.init(a, @splat(0xb1), options);
            defer host.deinit();
            var partner = support.init(a, @splat(0xb2), options);
            defer partner.deinit();
            var observer = support.init(a, @splat(0xb3), options);
            defer observer.deinit();
            var dials: std.ArrayList(h.ParkedDial) = .empty;
            defer {
                for (dials.items) |dial| a.free(dial.designator);
                dials.deinit(a);
            }
            const pair = try h.openPair(a, &host, &partner, "127.0.0.1:7971", &dials);
            const watch = try h.openPair(a, &host, &observer, "127.0.0.1:7972", &dials);
            _ = try pair.b.served.publish(&partner.vat, "widget", h.Widget, .{});
            var fetched: h.CapturedRef = .{};
            try host.vowOn(try host.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = h.CapturedRef.record });
            try h.pumpToQuiescence(a, &.{ &host, &partner }, &.{pair}, &dials);
            const remote = try host.liftCapability(pair.a, try fetched.require());

            const bytes = try signedGive(a);
            defer a.free(bytes);
            const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(a, bytes);
            defer model.freeHandoffGive(a, give);
            const promise = try host.acceptInlineGive(pair.a, give);
            const promise_id = host.capabilities.resolve(promise).?.deferred;
            _ = try host.lowerCapability(watch.a, promise);
            const dial = while (try host.nextAction()) |action| switch (action) {
                .dial => |dial| break dial,
                else => {},
            } else return error.MissingDial;

            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const send_vow = try host.queueSendValues(pair.a, promise, "poke", &.{.{ .capability = remote }}, arena.allocator());
            // The queued operation now owns the argument's last application retain.
            try host.releaseCapability(remote, 1);
            const budget = watch.a.served.port.peer.outbound_budget;
            watch.a.served.port.peer.outbound_budget = 0;
            try host.dialFailed(dial.ticket, dial.route_index, "unavailable");
            const row = host.capability_promises.get(promise_id).?;
            try std.testing.expect(row.state == .pending);
            try std.testing.expectEqual(@as(usize, 1), row.operations.items.len - row.operation_head);
            watch.a.served.port.peer.outbound_budget = budget;
            while (try watch.a.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }

            try host.vowRelease(send_vow);
            try std.testing.expect(host.vows.get(send_vow) == null);
            // The release consumed the argument's last retain exactly once.
            try std.testing.expect(host.capabilities.retainCount(remote) == null);
            try h.pumpToQuiescence(a, &.{ &host, &partner, &observer }, &.{ pair, watch }, &dials);
            try std.testing.expect(host.capability_promises.get(promise_id).?.state == .broken);
            try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
            try host.releaseCapability(promise, 1);
        }
    }
}
