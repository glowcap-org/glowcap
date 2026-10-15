//! Zig Server uses runtime-owned resident listeners and waits for their
//! physical stop before releasing callback storage or its final runtime lease.

const std = @import("std");
const glowcap = @import("glowcap");
const driver = glowcap.driver;
const net = glowcap.net;
const model = glowcap.ocapn.model;
const fixtures = @import("residents.zig");

const DelayedStop = struct {
    inner: fixtures.AcceptOwnershipResident,
    route: usize = 0,
    stop_calls: usize = 0,
    stop_ready: bool = false,
    fail_accept: bool = false,
    fail_stop: bool = false,

    fn from(ctx: *anyopaque) *DelayedStop {
        const inner: *fixtures.AcceptOwnershipResident = @ptrCast(@alignCast(ctx));
        return @fieldParentPtr("inner", inner);
    }
    fn resident(self: *DelayedStop) net.MultiplexedResident {
        return .{ .ctx = &self.inner, .vtable = &vtable };
    }
    const base = fixtures.AcceptOwnershipResident.vtable;
    const vtable: net.MultiplexedResident.VTable = blk: {
        var result = base;
        result.drain_ready = drain;
        result.listen.?.listen = listen;
        result.listen.?.stop_listen = stop;
        result.listen.?.finish_accept = accept;
        break :blk result;
    };
    fn listen(ctx: *anyopaque, route: usize, transport: []const u8, config: net.netlayer.ListenConfig) net.MultiplexedResident.RawListenStartOutcome {
        from(ctx).route = route;
        return base.listen.?.listen(ctx, route, transport, config);
    }
    fn accept(ctx: *anyopaque, listener: *anyopaque) net.MultiplexedResident.RawFinishAcceptOutcome {
        if (from(ctx).fail_accept) return .{ .failed = .init(error.ConnectionLost) };
        return base.listen.?.finish_accept(ctx, listener);
    }
    fn stop(ctx: *anyopaque, listener: *anyopaque) net.multiplexed_resident.TeardownOutcome {
        const self = from(ctx);
        self.stop_calls += 1;
        if (self.stop_calls == 1) {
            self.stop_ready = true;
            _ = self.inner.wake.nudge() catch return .{ .failed = .init(error.WakeNudgeFailed) };
            return .pending;
        }
        const outcome = base.listen.?.stop_listen(ctx, listener);
        if (self.fail_stop) return .{ .failed = .init(error.ConnectionLost) };
        return outcome;
    }
    fn drain(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = from(ctx);
        if (self.stop_ready and out.len != 0) {
            self.inner.wake.drain() catch return error.ProviderContract;
            self.stop_ready = false;
            out[0] = .{ .subject = self.route, .events = net.multiplexed_resident.ev_listen };
            return 1;
        }
        return base.drain_ready(ctx, out);
    }
};

test "Zig Server: resident close joins physical stop and advertisement refusal preserves the route" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var resident = DelayedStop{ .inner = try fixtures.AcceptOwnershipResident.init() };
    defer resident.inner.deinit();
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = .{ .symbol = fixtures.AcceptOwnershipResident.transport, .designator_scheme = .address },
        .resident = resident.resident(),
    }};
    const server = try driver.listen(allocator, threaded.io(), .{ .residents = &providers }, fixtures.AcceptOwnershipResident.transport, .{ .designator = "" }, .ephemeral, fixtures.opts);
    defer server.deinit();
    try std.testing.expectEqualStrings("resident.test:1", (try server.advertisedLocator()).designator);
    try std.testing.expectError(error.InvalidAddress, server.setAdvertisedLocator(.{
        .transport = fixtures.AcceptOwnershipResident.transport,
        .designator = "wrong.test:2",
        .hints = model.Hints.emptyFalse(),
    }));
    try std.testing.expectEqualStrings("resident.test:1", (try server.advertisedLocator()).designator);
    try std.testing.expect(!try server.waitAcceptable(0));
    try std.testing.expect(server.close() == null);
    try std.testing.expectEqual(@as(usize, 2), resident.stop_calls);
    try std.testing.expect(!resident.inner.listeners[0].active);
    try std.testing.expect(server.close() == null);
}

fn waitReady(server: *driver.Server) !bool {
    return server.waitAcceptable(0);
}

test "Zig Server: close claims a failure delivered during asynchronous stop" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var resident = DelayedStop{ .inner = try fixtures.AcceptOwnershipResident.init(), .fail_stop = true };
    defer resident.inner.deinit();
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = .{ .symbol = fixtures.AcceptOwnershipResident.transport, .designator_scheme = .address },
        .resident = resident.resident(),
    }};
    const server = try driver.listen(allocator, threaded.io(), .{ .residents = &providers }, fixtures.AcceptOwnershipResident.transport, .{ .designator = "" }, .ephemeral, fixtures.opts);
    defer server.deinit();
    const failure = server.close().?;
    try std.testing.expectEqual(error.ConnectionLost, failure.cause);
    try std.testing.expect(server.closed);
    try std.testing.expectEqual(@as(usize, 2), resident.stop_calls);
    try std.testing.expectEqual(error.ConnectionLost, server.close().?.cause);
}

test "Zig Server: ready wait releases affinity and close claims an unconsumed listener failure" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = DelayedStop{ .inner = try fixtures.AcceptOwnershipResident.init(), .fail_accept = true };
    defer resident.inner.deinit();
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = .{ .symbol = fixtures.AcceptOwnershipResident.transport, .designator_scheme = .address },
        .resident = resident.resident(),
    }};
    const server = try driver.listen(allocator, io, .{ .residents = &providers }, fixtures.AcceptOwnershipResident.transport, .{ .designator = "" }, .ephemeral, fixtures.opts);
    defer server.deinit();
    resident.inner.announceAccept();
    try std.testing.expect(try server.waitAcceptable(100));
    try std.testing.expect(try server.waitAcceptable(0));
    var moved_wait = try io.concurrent(waitReady, .{server});
    try std.testing.expect(try moved_wait.await(io));
    try std.testing.expectEqual(error.ConnectionLost, server.close().?.cause);
    try std.testing.expect(server.closed);
    try std.testing.expectEqual(error.ConnectionLost, server.close().?.cause);
}
