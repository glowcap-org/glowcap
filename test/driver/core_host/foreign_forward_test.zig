//! Foreign forwarding preserves the original local or wire answer owner.
const std = @import("std");
const driver = @import("glowcap").driver.core;
const support = @import("../../support/core_host.zig");
const pairs = @import("../../support/host_pair.zig");
const capture = @import("../../support/capture.zig");
const metrics = @import("../../support/alloc_metrics.zig");
const a = std.testing.allocator;

const Echo = struct {
    calls: *usize,
    pub fn handle(self: *Echo, turn: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.calls.* += 1;
        return arg_values[0];
    }
};
const Hop = struct {
    target: driver.Capability,
    fail: bool = false,
    finish: bool = false,
    pub fn handle(self: *Hop, turn: *driver.HostTurn, verb: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        if (self.finish) turn.host.beginClose(.{ .finish = .unbounded }, 0);
        const result = try turn.forward(self.target, verb, arg_values);
        if (self.fail) return error.Refused;
        return result;
    }
};
const Gift = struct {
    target: driver.Capability,
    pub fn handle(self: *Gift, turn: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
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

const WireResult = struct {
    value: ?i64 = null,
    broken: bool = false,
    fn record(ctx: ?*anyopaque, resolution: @import("glowcap").actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| if (value == .integer) {
                self.value = value.integer;
            },
            .broken, .give => self.broken = true,
        }
    }
};

fn fetch(host: *driver.Host, pair: pairs.Pair, swiss: []const u8) !driver.Capability {
    var found: capture.CapturedRef = .{};
    try host.vowOn(try host.fetch(pair.a, swiss), .{ .ctx = &found, .func = capture.CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    return host.liftCapability(pair.a, try found.require());
}

test "core host wire foreign forwarding owns both session lifetimes" {
    for ([_]enum { ready, tell, fail, finish, source_cancel, queued_reply_cancel, destination_cancel, destination_finish, released_answer }{
        .ready, .tell, .fail, .finish, .source_cancel, .queued_reply_cancel, .destination_cancel, .destination_finish, .released_answer,
    }) |boundary| {
        var client = support.init(a, @splat(0xa1), driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        var middle = support.init(a, @splat(0xa2), driver.Host.Options.withFrameCap(4096));
        defer middle.deinit();
        var exporter = support.init(a, @splat(0xa3), driver.Host.Options.withFrameCap(4096));
        defer exporter.deinit();
        var calls: usize = 0;
        const target = try spawn(&exporter, Echo, .{ .calls = &calls });
        defer exporter.releaseCapabilityTerminal(target, null);
        const destination = try pairs.openPair(&middle, &exporter, "127.0.0.1:7941");
        const target_swiss = try exporter.publishDurableCapability(@splat(0x61), target);
        const imported = try fetch(&middle, destination, target_swiss.slice());
        defer middle.releaseCapabilityTerminal(imported, null);
        const hop = try spawn(&middle, Hop, .{ .target = imported, .fail = boundary == .fail, .finish = boundary == .finish });
        defer middle.releaseCapabilityTerminal(hop, null);
        const source = try pairs.openPair(&client, &middle, "127.0.0.1:7942");
        const hop_swiss = try middle.publishDurableCapability(@splat(0x62), hop);
        const remote = try fetch(&client, source, hop_swiss.slice());
        defer client.releaseCapabilityTerminal(remote, null);
        if (boundary == .destination_finish)
            try middle.beginSessionClose(destination.a, .{ .finish = .unbounded }, 0);
        var result: WireResult = .{};
        var released_vow: ?u64 = null;
        if (boundary == .tell) {
            try client.tellValues(source.a, remote, "echo", &.{.{ .integer = 37 }}, a);
        } else {
            const vow = try client.sendValues(source.a, remote, "echo", &.{.{ .integer = 37 }}, a);
            if (boundary == .released_answer) {
                released_vow = vow;
            } else try client.vowOn(vow, .{ .ctx = &result, .func = WireResult.record });
        }
        _ = try pairs.shuttle(source);
        if (released_vow) |vow| {
            try client.vowRelease(vow);
            _ = try pairs.shuttle(source);
        }
        if (boundary == .queued_reply_cancel) {
            while (try destination.a.takeOutbound()) |outbound| {
                var frame = outbound;
                defer frame.deinit();
                try exporter.feed(destination.b, frame.view());
            }
            while (try destination.b.takeOutbound()) |frame|
                try destination.a.served.port.peer.feedOwned(frame);
            try destination.a.served.port.peer.stepToIdle();
            try std.testing.expect(destination.a.served.port.peer.hasEvent());
            try std.testing.expectEqual(@as(usize, 1), middle.vows.count());
        }
        if (boundary == .source_cancel or boundary == .queued_reply_cancel) {
            try middle.releaseSession(source.b);
            while (destination.a.served.port.peer.pollEvent()) |item| {
                var event = item;
                try middle.serveEvent(destination.a, &event);
            }
            try pairs.pumpToQuiescence(&.{destination});
        } else if (boundary == .destination_cancel) {
            try middle.releaseSession(destination.a);
            try pairs.pumpToQuiescence(&.{source});
        } else {
            try pairs.pumpToQuiescence(&.{ source, destination });
        }
        switch (boundary) {
            .ready, .finish => try std.testing.expectEqual(@as(?i64, 37), result.value),
            .tell, .released_answer => try std.testing.expectEqual(@as(usize, 1), calls),
            .fail, .destination_cancel, .destination_finish => try std.testing.expect(result.broken),
            .source_cancel, .queued_reply_cancel => {},
        }
        if (boundary == .fail) try std.testing.expectEqual(@as(usize, 0), calls);
        try std.testing.expectEqual(@as(usize, 0), middle.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), middle.pendingVowCount());
        try std.testing.expectEqual(@as(usize, 0), middle.vows.count());
    }
}

test "core host wire foreign forwarding preserves capability arguments and replies" {
    try capabilityRoundtrip(true);
    try capabilityRoundtrip(false);
}

fn capabilityRoundtrip(observe_reply: bool) !void {
    const wire = @import("harness.zig");
    var client = support.init(a, @splat(0xb1), wire.nextRouteOptions());
    defer client.deinit();
    var middle = support.init(a, @splat(0xb2), wire.nextRouteOptions());
    defer middle.deinit();
    var exporter = support.init(a, @splat(0xb3), wire.nextRouteOptions());
    defer exporter.deinit();
    var dials: std.ArrayList(wire.ParkedDial) = .empty;
    defer wire.deinitParked(a, &dials);
    try client.setAdvertisedLocator(wire.tcpLocator("127.0.0.1:7950"));
    try middle.setAdvertisedLocator(wire.tcpLocator("127.0.0.1:7952"));
    const destination = try wire.openPair(a, &middle, &exporter, "127.0.0.1:7951", &dials);
    const source = try wire.openPair(a, &client, &middle, "127.0.0.1:7952", &dials);
    const hosts = [_]*driver.Host{ &client, &middle, &exporter };
    var calls: usize = 0;
    const target = try spawn(&exporter, Echo, .{ .calls = &calls });
    defer exporter.releaseCapabilityTerminal(target, null);
    const target_name = try exporter.publishDurableCapability(@splat(0x71), target);
    const imported = try fetch(&middle, destination, target_name.slice());
    defer middle.releaseCapabilityTerminal(imported, null);
    const hop = try spawn(&middle, Hop, .{ .target = imported });
    defer middle.releaseCapabilityTerminal(hop, null);
    const hop_name = try middle.publishDurableCapability(@splat(0x72), hop);
    const remote = try fetch(&client, source, hop_name.slice());
    defer client.releaseCapabilityTerminal(remote, null);
    var local_calls: usize = 0;
    const original = try spawn(&client, Echo, .{ .calls = &local_calls });
    defer client.releaseCapabilityTerminal(original, null);
    const call = try client.callCapability(a, source.a, remote, "echo", &.{.{ .list = &.{
        .{ .capability = original }, .{ .capability = original },
    } }}, 4096);
    var call_live = true;
    defer if (call_live) call.deinit();
    try wire.pumpToQuiescence(a, &hosts, &.{ source, destination }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    if (!observe_reply) {
        call.deinit();
        call_live = false;
        try wire.pumpToQuiescence(a, &hosts, &.{ source, destination }, &dials);
    }
    const dial = dials.orderedRemove(0);
    try std.testing.expect(dial.host == &exporter);
    try std.testing.expectEqualStrings("127.0.0.1:7950", dial.designator);
    const pending = exporter.pendingDial(dial.ticket, dial.route_index) orelse return error.MissingPendingDial;
    const accepted = try client.openAcceptedAdvertised("tcp");
    const dialed = try exporter.openDialedLocator(pending.locator);
    const direct: wire.Pair = .{ .ah = &exporter, .a = dialed, .bh = &client, .b = accepted };
    var network: std.ArrayList(wire.Pair) = .empty;
    defer network.deinit(a);
    try network.appendSlice(a, &.{ source, destination, direct });
    try wire.pumpToQuiescence(a, &hosts, network.items, &dials);
    _ = try exporter.exporterDialed(dial.ticket, dial.route_index, dialed);
    a.free(dial.designator);
    try driveReturnedCapabilities(&client, &hosts, &network, &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), middle.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), middle.vows.count());
    try std.testing.expect(source.b.sessionOpen());
    if (!observe_reply) {
        try std.testing.expectEqual(@as(?u64, 1), client.capabilities.retainCount(original));
        return;
    }
    try std.testing.expect(call.result() == .ready);
    const returned = call.result().ready.list;
    try std.testing.expectEqual(@as(usize, 2), returned.len);
    // A redeemed handoff may keep its promise identity. Exercise both copies
    // against the original actor instead of requiring identical opaque IDs.
    for (returned, 0..) |value, index| {
        var result: WireResult = .{};
        const number: i64 = @intCast(43 + index);
        const probe = try client.sendApplicationValues(value.capability, "echo", &.{.{ .integer = number }}, a);
        try client.vowOn(probe, .{ .ctx = &result, .func = WireResult.record });
        try driveReturnedCapabilities(&client, &hosts, &network, &dials);
        try std.testing.expectEqual(@as(?i64, number), result.value);
    }
    try std.testing.expectEqual(@as(usize, 2), local_calls);
}

// Returned promises can require another introduction to the original client.
// Honor each actual dial, including a self-connection, rather than assuming
// an unauthenticated accepted connection can be reused in the opposite role.
fn driveReturnedCapabilities(client: *driver.Host, hosts: []const *driver.Host, network: *std.ArrayList(pairs.Pair), dials: *std.ArrayList(@import("harness.zig").ParkedDial)) !void {
    const wire = @import("harness.zig");
    var opened: usize = 0;
    while (true) {
        try wire.pumpToQuiescence(a, hosts, network.items, dials);
        if (dials.items.len == 0) return;
        if (opened == 8) return error.TooManyRedemptionDials;
        opened += 1;
        const dial = dials.orderedRemove(0);
        defer a.free(dial.designator);
        try std.testing.expectEqualStrings("127.0.0.1:7950", dial.designator);
        const pending = dial.host.pendingDial(dial.ticket, dial.route_index) orelse return error.MissingPendingDial;
        const accepted = try client.openAcceptedAdvertised("tcp");
        const dialed = try dial.host.openDialedLocator(pending.locator);
        try network.append(a, .{ .ah = dial.host, .a = dialed, .bh = client, .b = accepted });
        try wire.pumpToQuiescence(a, hosts, network.items, dials);
        _ = try dial.host.exporterDialed(dial.ticket, dial.route_index, dialed);
    }
}
