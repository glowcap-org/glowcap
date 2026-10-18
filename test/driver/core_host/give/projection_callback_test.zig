//! Terminal promise projection failure can synchronously fire far-vow listeners.
//! Those listeners may project the same promise or grow the Host promise map.
//! Omitting row reacquisition was verified to crash after callback map growth.
//! Fixture gives stop at introducer closure; no successful withdrawal is claimed.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("../harness.zig");
const support = @import("../../../support/core_host.zig");
const signedGive = @import("../../../engine/node/harness.zig").testGiveBytes;
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

const Probe = struct {
    host: *Host,
    session: *glowcap.driver.core.HostSession,
    failing: *std.testing.FailingAllocator,
    promise: glowcap.driver.core.Capability,
    give: *model.Handoff,
    grow: bool,
    projection: ?model.Reference = null,
    failure: ?anyerror = null,
    calls: usize = 0,
    created: [128]glowcap.driver.core.Capability = undefined,
    count: usize = 0,

    fn fire(context: ?*anyopaque, resolution: glowcap.actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.failing.fail_index = std.math.maxInt(usize);
        if (resolution != .broken) {
            self.failure = error.ExpectedBrokenVow;
            return;
        }
        self.projection = self.host.lowerCapability(self.session, self.promise) catch |err| {
            self.failure = err;
            return;
        };
        if (!self.grow) return;
        const capacity = self.host.capability_promises.capacity();
        while (self.host.capability_promises.capacity() == capacity and self.count < self.created.len) {
            const value = self.host.liftValue(self.session, a, .{ .handoff = self.give }) catch |err| {
                self.failure = err;
                return;
            };
            self.created[self.count] = value.capability;
            self.count += 1;
        }
        if (self.host.capability_promises.capacity() == capacity) self.failure = error.PromiseMapDidNotGrow;
    }
};

test "core host: terminal projection callback preserves appended projections and survives promise map growth" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
            for ([_]bool{ false, true }) |grow| {
                var failing = std.testing.FailingAllocator.init(a, .{});
                var options = Host.Options.withFrameCap(h.frame_cap);
                options.captp_version = profile;
                options.codec = codec;
                options.features = model.FeatureSet.full().forCaptpVersion(profile);
                var host = support.init(failing.allocator(), @splat(0xa1), options);
                defer host.deinit();
                var introducer = support.init(a, @splat(0xa2), options);
                defer introducer.deinit();
                var failed = support.init(a, @splat(0xa3), options);
                defer failed.deinit();
                var healthy = support.init(a, @splat(0xa4), options);
                defer healthy.deinit();
                var dials: std.ArrayList(h.ParkedDial) = .empty;
                defer {
                    for (dials.items) |dial| a.free(dial.designator);
                    dials.deinit(a);
                }
                const intro = try h.openPair(a, &host, &introducer, "127.0.0.1:7961", &dials);
                const recipient = try h.openPair(a, &host, &failed, "127.0.0.1:7962", &dials);
                const live = try h.openPair(a, &host, &healthy, "127.0.0.1:7963", &dials);
                const bytes = try signedGive(a);
                defer a.free(bytes);
                const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(a, bytes);
                defer model.freeHandoffGive(a, give);
                var handoff: model.Handoff = .{ .give = give };
                const promise = try host.acceptInlineGive(intro.a, give);
                const dial = (try host.nextAction()).?.dial;
                _ = try host.lowerCapability(recipient.a, promise);
                var probe: Probe = .{
                    .host = &host,
                    .session = live.a,
                    .failing = &failing,
                    .promise = promise,
                    .give = &handoff,
                    .grow = grow,
                };
                const pending = try host.fetch(recipient.a, "not-yet-delivered");
                try host.vowOn(pending, .{ .ctx = &probe, .func = Probe.fire });
                // The first terminal projection cannot retain its break text.
                // Its condemnation callback restores allocation before lifting.
                failing.fail_index = failing.alloc_index;
                try host.releaseSession(intro.a);
                failing.fail_index = std.math.maxInt(usize);
                if (probe.failure) |err| return err;
                try std.testing.expectEqual(@as(usize, 1), probe.calls);
                const projected = probe.projection orelse return error.CallbackDidNotProject;
                try std.testing.expect(projected == .near);
                try std.testing.expect(live.a.sessionOpen());
                try std.testing.expect(live.a.served.port.peer.session_state.answerForLocalPromiseExport(projected.near.export_position) == null);
                try std.testing.expectError(error.PromiseBroken, host.routeCapability(live.a, promise, .object_only));
                try host.releaseCapability(promise, 1);
                for (probe.created[0..probe.count]) |ref| try host.releaseCapability(ref, 1);
                try host.dialFailed(dial.ticket, dial.route_index, "unavailable");
                try std.testing.expectEqual(@as(usize, 0), host.capability_promises.count());
                try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
            }
        }
    }
}
