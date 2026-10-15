//! Local answer chains keep one result owner across actual foreign delivery.
const std = @import("std");
const driver = @import("glowcap").driver.core;
const support = @import("../../support/core_host.zig");
const pairs = @import("../../support/host_pair.zig");
const capture = @import("../../support/capture.zig");
const metrics = @import("../../support/alloc_metrics.zig");
const a = std.testing.allocator;

const Echo = struct {
    calls: *usize,
    pub fn handle(self: *Echo, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.calls.* += 1;
        return arg_values[0];
    }
};
const Hop = struct {
    target: driver.Capability,
    fail: bool = false,
    pub fn handle(self: *Hop, turn: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        const result = try turn.forward(self.target, verb, arg_values);
        if (self.fail) return error.Refused;
        return result;
    }
};
const Gift = struct {
    target: driver.Capability,
    pub fn handle(self: *Gift, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        return .{ .capability = self.target };
    }
};

fn spawn(host: *driver.Host, comptime B: type, initial: B) !driver.Capability {
    const reservation = try host.reserveFreshCapability(null);
    const actor = try host.vat.spawn(driver.Hosting(B), .{ .inner = initial });
    return host.adoptReservedLocalCapability(reservation, actor);
}

fn allocationRefusal(failure_index: usize) !bool {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var host = support.init(failing.allocator(), @splat(0x96), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var exporter = support.init(a, @splat(0x97), driver.Host.Options.withFrameCap(4096));
    defer exporter.deinit();
    var calls: usize = 0;
    const target = try spawn(&exporter, Echo, .{ .calls = &calls });
    defer exporter.releaseCapabilityTerminal(target, null);
    const swiss = try exporter.publishDurableCapability(@splat(0x54), target);
    const pair = try pairs.openPair(&host, &exporter, "127.0.0.1:7934");
    var fetched: capture.CapturedRef = .{};
    try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = capture.CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const imported = try host.liftCapability(pair.a, try fetched.require());
    defer host.releaseCapabilityTerminal(imported, null);
    const ref = try spawn(&host, Hop, .{ .target = imported });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "echo", &.{.{ .list = &.{ .{ .capability = imported }, .{ .capability = imported } } }}, 4096);
    defer call.deinit();
    failing.fail_index = failing.alloc_index + failure_index;
    host.vat.drive() catch |err| try std.testing.expectEqual(error.OutOfMemory, err);
    // Fault only the forwarding admission window, then drive committed work.
    failing.fail_index = std.math.maxInt(usize);
    while (try host.nextAction()) |_| {}
    try pairs.pumpToQuiescence(&.{pair});
    if (call.result() == .failed) {
        try std.testing.expectEqualStrings("OutOfMemory", call.result().failed.message);
        try std.testing.expectEqual(@as(usize, 0), calls);
        try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(imported));
    } else {
        try std.testing.expectEqual(imported, call.result().ready.list[0].capability);
        try std.testing.expectEqual(imported, call.result().ready.list[1].capability);
        try std.testing.expectEqual(@as(usize, 1), calls);
    }
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), pair.a.served.port.far_listeners.count());
    return failing.has_induced_failure;
}

test "core host local foreign forwarding allocation refusals retire every completion owner" {
    for (0..128) |index| if (!try allocationRefusal(index)) return;
    return error.AllocationSweepDidNotComplete;
}

test "core host local foreign forwarding shares exact bounded result through queued hops" {
    for ([_]enum { ready, cancel, fail, finish, retire, session_finish, capacity }{ .ready, .cancel, .fail, .finish, .retire, .session_finish, .capacity }) |boundary| {
        var host = support.init(a, @splat(0x91), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var exporter = support.init(a, @splat(0x92), driver.Host.Options.withFrameCap(4096));
        defer exporter.deinit();
        var calls: usize = 0;
        const target = try spawn(&exporter, Echo, .{ .calls = &calls });
        defer exporter.releaseCapabilityTerminal(target, null);
        const swiss = try exporter.publishDurableCapability(@splat(0x51), target);
        const pair = try pairs.openPair(&host, &exporter, "127.0.0.1:7931");
        var fetched: capture.CapturedRef = .{};
        try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = capture.CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const imported = try host.liftCapability(pair.a, try fetched.require());
        defer host.releaseCapabilityTerminal(imported, null);
        const first = try spawn(&host, Hop, .{ .target = imported, .fail = boundary == .fail });
        defer host.releaseCapabilityTerminal(first, null);
        const second = try spawn(&host, Hop, .{ .target = first });
        defer host.releaseCapabilityTerminal(second, null);
        var live: metrics.LiveBytesAllocator = .{ .backing = a };
        var counted: metrics.CountingAllocator = .{ .backing = live.allocator() };
        const reply_bytes: usize = if (boundary == .capacity) 1 else 4096;
        const call = try host.callLocalCapability(counted.allocator(), second, "echo", &.{.{ .list = &.{ .{ .capability = imported }, .{ .@"struct" = &.{.{ .key = "same", .value = .{ .capability = imported } }} } } }}, reply_bytes);
        var observed = true;
        defer if (observed) call.deinit();
        if (boundary == .cancel) {
            call.deinit();
            observed = false;
        }
        if (boundary == .finish) host.beginClose(.{ .finish = .unbounded }, 0);
        if (boundary == .session_finish) try host.beginSessionClose(pair.a, .{ .finish = .unbounded }, 0);
        if (boundary == .session_finish) {
            try host.vat.drive();
        } else {
            while (try host.nextAction()) |_| {}
        }
        if (boundary == .retire) try host.releaseSession(pair.a);
        if (boundary != .retire) try pairs.pumpToQuiescence(&.{pair});
        if (observed) switch (boundary) {
            .ready, .finish => {
                try std.testing.expect(call.result() == .ready);
                try std.testing.expectEqual(imported, call.result().ready.list[0].capability);
                try std.testing.expectEqual(imported, call.result().ready.list[1].@"struct"[0].value.capability);
            },
            .fail => try std.testing.expectEqualStrings("Refused", call.result().failed.message),
            .retire => try std.testing.expectEqual(@as(@TypeOf(call.result().failed.kind), .closed), call.result().failed.kind),
            .session_finish => try std.testing.expectEqualStrings("SessionClosing", call.result().failed.message),
            .capacity => try std.testing.expectEqualStrings("ReplyCapacity", call.result().failed.message),
            .cancel => unreachable,
        };
        try std.testing.expectEqual(@as(usize, if (boundary == .fail or boundary == .retire or boundary == .session_finish) 0 else 1), calls);
        try std.testing.expectEqual(@as(usize, 2), counted.allocs);
        try std.testing.expectEqual(if (observed) try driver.Host.Call.sizeBound(reply_bytes) else 0, live.liveBytes());
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), host.pendingVowCount());
        try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        if (boundary != .retire) try std.testing.expectEqual(@as(?u64, if (boundary == .ready or boundary == .finish) 3 else 1), host.capabilities.retainCount(imported));
        if (observed) {
            call.deinit();
            observed = false;
        }
        try std.testing.expectEqual(@as(u64, 0), live.liveBytes());
    }
}

test "core host local foreign forwarding retracts third-party introductions on failed outer turn" {
    const wire = @import("harness.zig");
    var host = support.init(a, @splat(0x93), driver.Host.Options.withFrameCap(wire.frame_cap));
    defer host.deinit();
    var exporter = support.init(a, @splat(0x94), driver.Host.Options.withFrameCap(wire.frame_cap));
    defer exporter.deinit();
    var third = support.init(a, @splat(0x95), driver.Host.Options.withFrameCap(wire.frame_cap));
    defer third.deinit();
    var dials: std.ArrayList(wire.ParkedDial) = .empty;
    defer dials.deinit(a);
    const first = try wire.openPair(a, &host, &exporter, "127.0.0.1:7932", &dials);
    const second = try wire.openPair(a, &host, &third, "127.0.0.1:7933", &dials);
    const hosts = [_]*driver.Host{ &host, &exporter, &third };
    const network = [_]wire.Pair{ first, second };
    var calls: usize = 0;
    const target = try spawn(&exporter, Echo, .{ .calls = &calls });
    defer exporter.releaseCapabilityTerminal(target, null);
    const target_name = try exporter.publishDurableCapability(@splat(0x52), target);
    const gift = try spawn(&third, Echo, .{ .calls = &calls });
    defer third.releaseCapabilityTerminal(gift, null);
    const vendor = try spawn(&third, Gift, .{ .target = gift });
    defer third.releaseCapabilityTerminal(vendor, null);
    const vendor_name = try third.publishDurableCapability(@splat(0x53), vendor);
    var fetched_target: capture.CapturedRef = .{};
    var fetched_vendor: capture.CapturedRef = .{};
    try host.vowOn(try host.fetch(first.a, target_name.slice()), .{ .ctx = &fetched_target, .func = capture.CapturedRef.record });
    try host.vowOn(try host.fetch(second.a, vendor_name.slice()), .{ .ctx = &fetched_vendor, .func = capture.CapturedRef.record });
    try wire.pumpToQuiescence(a, &hosts, &network, &dials);
    const imported_target = try host.liftCapability(first.a, try fetched_target.require());
    defer host.releaseCapabilityTerminal(imported_target, null);
    const imported_vendor = try host.liftCapability(second.a, try fetched_vendor.require());
    defer host.releaseCapabilityTerminal(imported_vendor, null);
    // A plain call result has not enrolled this third-party import as a route.
    const gift_call = try host.callCapability(a, second.a, imported_vendor, "gift", &.{}, 4096);
    var gift_observed = true;
    defer if (gift_observed) gift_call.deinit();
    try wire.pumpToQuiescence(a, &hosts, &network, &dials);
    const held = gift_call.result().ready.capability;
    const home = host.capabilities.resolve(held).?.remote;
    try std.testing.expect(second.a.served.port.peer.session_state.foreignRouteIdFor(home.far.import_position) == null);
    const retains = host.capabilities.retainCount(held);
    const ref = try spawn(&host, Hop, .{ .target = imported_target, .fail = true });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "take", &.{.{ .list = &.{ .{ .capability = held }, .{ .capability = held } } }}, 4096);
    defer call.deinit();
    try host.vat.drive();
    try wire.pumpToQuiescence(a, &hosts, &network, &dials);
    try std.testing.expectEqualStrings("Refused", call.result().failed.message);
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqual(retains, host.capabilities.retainCount(held));
    try std.testing.expectEqual(@as(usize, 0), host.node.inline_passable_batches.rows.count());
    try std.testing.expectEqual(@as(usize, 0), host.node.pendingGiftEffects());
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.pendingVowCount());
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), first.a.served.port.far_listeners.count());
    try std.testing.expectEqual(@as(usize, 0), second.a.served.port.far_listeners.count());
    try std.testing.expect(second.a.served.port.peer.session_state.foreignRouteIdFor(home.far.import_position) != null);
    gift_call.deinit();
    gift_observed = false;
    try std.testing.expect(second.a.served.port.peer.session_state.foreignRouteIdFor(home.far.import_position) == null);
    try std.testing.expect(host.capabilities.retainCount(held) == null);
}
