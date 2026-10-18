//! Exercise final release of an actually redeemed inline-give identity while
//! its remote home fails terminal GC publication and fires a pending listener.
const std = @import("std");
const glowcap = @import("glowcap");
const Host = glowcap.driver.core.Host;
const HostSession = glowcap.driver.core.HostSession;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

const Probe = struct {
    host: *Host,
    home: *HostSession,
    introducer: *HostSession,
    handoff: *model.Handoff,
    created: [128]glowcap.driver.core.Capability = undefined,
    count: usize = 0,
    calls: usize = 0,
    failure: ?anyerror = null,

    fn fire(context: ?*anyopaque, resolution: glowcap.actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.home.served.port.peer.outbound_budget = std.math.maxInt(usize);
        if (resolution != .broken) {
            self.failure = error.ExpectedBrokenVow;
            return;
        }
        const capacity = self.host.capability_promises.capacity();
        while (self.host.capability_promises.capacity() == capacity and self.count < self.created.len) {
            const value = self.host.liftValue(self.introducer, a, .{ .handoff = self.handoff }) catch |err| {
                self.failure = err;
                return;
            };
            self.created[self.count] = value.capability;
            self.count += 1;
        }
        if (self.host.capability_promises.capacity() == capacity) self.failure = error.PromiseMapDidNotGrow;
    }
};

pub fn exercise(host: *Host, home: *HostSession, introducer: *HostSession, handoff: *model.Handoff, promise: glowcap.driver.core.Capability) !void {
    // The fixture holds its original top-level reply while re-embedding the
    // signed give. Preserve that unrelated operation across this release.
    const baseline_operations = host.pending_operations;
    var probe: Probe = .{ .host = host, .home = home, .introducer = introducer, .handoff = handoff };
    const pending = try host.fetch(home, "not-yet-delivered");
    try host.vowOn(pending, .{ .ctx = &probe, .func = Probe.fire });
    try std.testing.expectEqual(baseline_operations + 1, host.pending_operations);
    home.served.port.peer.outbound_budget = 0;
    try host.releaseCapability(promise, 1);
    if (probe.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(home.isTerminating());
    for (probe.created[0..probe.count]) |ref| try host.releaseCapability(ref, 1);
    while (try host.nextAction()) |action| switch (action) {
        .dial => |dial| try host.dialFailed(dial.ticket, dial.route_index, "unavailable"),
        .cancel_dial => |dial| try host.dialCancelled(dial.ticket, dial.route_index),
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), host.capability_promises.count());
    try std.testing.expectEqual(baseline_operations, host.pending_operations);
}
