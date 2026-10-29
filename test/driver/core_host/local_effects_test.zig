//! Callback children share actual admission, queue rollback and public actions.
const std = @import("std");
const glowcap = @import("glowcap");
const driver = glowcap.driver.core;
const support = @import("../../support/core_host.zig");
const pairs = @import("../../support/host_pair.zig");
const capture = @import("../../support/capture.zig");
const a = std.testing.allocator;
const metrics = @import("../../support/alloc_metrics.zig");

const Child = struct {
    calls: *usize,
    resolver: ?*u64 = null,
    pub fn handle(self: *@This(), turn: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.calls.* += 1;
        if (self.resolver) |slot| {
            slot.* = try turn.deferAnswer();
            return .{ .void = {} };
        }
        return arg_values[0];
    }
};
const WireChild = struct {
    calls: *usize,
    pub fn handle(self: *@This(), turn: *glowcap.actors.Turn, msg: glowcap.actors.Delivery) !glowcap.ocapn.model.Argument {
        self.calls.* += 1;
        return (try msg.arg(0)).toOwned(turn.arena);
    }
};
const Parent = struct {
    target: driver.Capability,
    vow: *u64,
    tell: bool,
    fail: bool = false,
    pub fn handle(self: *@This(), turn: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        if (self.tell) try turn.tell(self.target, "echo", arg_values) else self.vow.* = try turn.send(self.target, "echo", arg_values);
        if (self.fail) return error.Refused;
        return .{ .void = {} };
    }
};
const Hop = struct {
    target: driver.Capability,
    pub fn handle(self: *@This(), turn: *driver.HostTurn, verb: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        return turn.forward(self.target, verb, arg_values);
    }
};
fn spawn(host: *driver.Host, comptime B: type, initial: B) !driver.Capability {
    const reservation = try host.reserveFreshCapability(null);
    const actor = try host.vat.spawn(driver.Hosting(B), .{ .inner = initial });
    return host.adoptReservedLocalCapability(reservation, actor);
}

test "core host ingress configuration admits bounded file payloads and freezes before effects" {
    for ([_]bool{ false, true }) |configured| {
        var counted: metrics.CountingAllocator = .{ .backing = a };
        var host = support.init(counted.allocator(), @splat(0xaa), .{});
        defer host.deinit();
        const before = counted.allocs;
        try std.testing.expectError(error.InvalidArgument, host.setIngressLimits(.{ .max_pending_turns = 0 }));
        try std.testing.expectError(error.InvalidArgument, host.setIngressLimits(.{ .max_pending_bytes = 100, .max_chunk_bytes = 101 }));
        if (configured) try host.setIngressLimits(.{ .max_chunk_bytes = 128 * 1024 });
        try std.testing.expectEqual(before, counted.allocs);
        var calls: usize = 0;
        const child = try spawn(&host, Child, .{ .calls = &calls });
        defer host.releaseCapabilityTerminal(child, null);
        const bytes = try a.alloc(u8, 64 * 1024);
        defer a.free(bytes);
        @memset(bytes, 7);
        const args = [_]driver.Value{.{ .bytes = bytes }};
        if (!configured) {
            try std.testing.expectError(error.ResourceExhausted, host.callLocalCapability(a, child, "write", &args, bytes.len));
            try std.testing.expectEqual(@as(usize, 0), calls);
            try std.testing.expectEqual(@as(usize, 0), host.vat.local_ingress.pending_turns);
        } else {
            const call = try host.callLocalCapability(a, child, "write", &args, bytes.len);
            defer call.deinit();
            try std.testing.expectError(error.HostNotQuiescent, host.setIngressLimits(.{}));
            while (try host.nextAction()) |_| {}
            try std.testing.expectEqual(@as(usize, 1), calls);
            try std.testing.expectEqualSlices(u8, bytes, call.result().ready.bytes);
        }
    }
    var host = support.init(a, @splat(0xab), .{});
    defer host.deinit();
    const ingress = try host.vat.openIngress();
    try host.vat.closeIngress(ingress);
    try std.testing.expectError(error.HostNotQuiescent, host.setIngressLimits(.{}));
}

test "core host local callback effects share admission and rollback through actual homes" {
    for ([_]bool{ false, true }) |remote| for ([_]bool{ false, true }) |forwarded| for ([_]bool{ false, true }) |tell| for ([_]enum { ready, failed, finish, cancel_observer, session_finish }{ .ready, .failed, .finish, .cancel_observer, .session_finish }) |mode| {
        if (mode == .session_finish and !remote) continue;
        var host = support.init(a, @splat(0xa1), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var exporter = support.init(a, @splat(0xa2), driver.Host.Options.withFrameCap(4096));
        defer exporter.deinit();
        var calls: usize = 0;
        const actor = try exporter.vat.spawn(WireChild, .{ .calls = &calls });
        const foreign = try exporter.retainLocalCapability(actor);
        defer exporter.releaseCapabilityTerminal(foreign, null);
        const swiss = try exporter.publishDurableCapability(@splat(0x61), foreign);
        const pair = try pairs.openPair(&host, &exporter, "127.0.0.1:7940");
        var fetched: capture.CapturedRef = .{};
        try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = capture.CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const imported = try host.liftCapability(pair.a, try fetched.require());
        defer host.releaseCapabilityTerminal(imported, null);
        const near = try spawn(&host, Child, .{ .calls = &calls });
        defer host.releaseCapabilityTerminal(near, null);
        const leaf = if (remote) imported else near;
        const hop = try spawn(&host, Hop, .{ .target = leaf });
        defer host.releaseCapabilityTerminal(hop, null);
        var vow: u64 = 0;
        const parent = try spawn(&host, Parent, .{ .target = if (forwarded) hop else leaf, .vow = &vow, .tell = tell, .fail = mode == .failed });
        defer host.releaseCapabilityTerminal(parent, null);
        const call = try host.callLocalCapability(a, parent, "start", &.{.{ .list = &.{ .{ .capability = near }, .{ .capability = near } } }}, 512);
        defer call.deinit();
        if (mode == .finish) host.beginClose(.{ .finish = .unbounded }, 0);
        if (mode == .session_finish) {
            try host.beginSessionClose(pair.a, .{ .finish = .unbounded }, 0);
            try host.vat.drive();
        }
        if (mode == .cancel_observer) {
            _ = try host.vat.driveBudgeted(1);
            if (!tell) {
                if (!remote or forwarded)
                    try std.testing.expectError(error.SessionlessVow, host.vowOn(vow, .{ .ctx = &fetched, .func = capture.CapturedRef.record }));
                try host.vowRelease(vow);
            }
        }
        var completed: usize = 0;
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            while (try host.takeAction()) |action| {
                defer host.freeAction(action);
                switch (action) {
                    .settled => |value| {
                        try std.testing.expect(!tell and mode != .failed and mode != .cancel_observer and mode != .session_finish);
                        try std.testing.expectEqual(vow, value.vow_id);
                        try std.testing.expectEqual(if (remote and !forwarded) @as(?glowcap.ocapn.engine.PeerHandle, pair.a.peer_handle) else null, value.peer_handle);
                        try std.testing.expectEqual(near, value.value.list[0].capability);
                        try std.testing.expectEqual(near, value.value.list[1].capability);
                        // The action, rather than its public handle, owns this reply.
                        try host.vowRelease(vow);
                        try std.testing.expect(host.capabilities.resolve(value.value.list[0].capability) != null);
                        completed += 1;
                    },
                    .failed => |value| {
                        try std.testing.expect(!tell and (mode == .failed or (mode == .session_finish and forwarded)));
                        try std.testing.expectEqual(vow, value.vow_id);
                        try std.testing.expectEqualStrings(if (mode == .failed) "Refused" else "SessionClosing", value.message.bytes());
                        try host.vowRelease(vow);
                        completed += 1;
                    },
                    else => {},
                }
            }
            if (!try pairs.shuttle(pair) and !host.hasRunnableWork()) break;
        }
        try std.testing.expect(rounds < 64);
        try std.testing.expectEqual(@as(usize, if (mode == .failed or mode == .session_finish) 0 else 1), calls);
        try std.testing.expectEqual(@as(usize, if (tell or mode == .cancel_observer or (mode == .session_finish and !forwarded)) 0 else 1), completed);
        try std.testing.expect(if (mode == .failed or (mode == .session_finish and !forwarded)) call.result() == .failed else call.result() == .ready);
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(near));
    };
}

test "core host local callback effects defer exact public custody and cancel only observation" {
    for ([_]bool{ false, true }) |cancel| {
        var host = support.init(a, @splat(0xa3), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var calls: usize = 0;
        var resolver: u64 = 0;
        const child = try spawn(&host, Child, .{ .calls = &calls, .resolver = &resolver });
        defer host.releaseCapabilityTerminal(child, null);
        var vow: u64 = 0;
        const parent = try spawn(&host, Parent, .{ .target = child, .vow = &vow, .tell = false });
        defer host.releaseCapabilityTerminal(parent, null);
        const call = try host.callLocalCapability(a, parent, "start", &.{.{ .integer = 1 }}, 512);
        defer call.deinit();
        while (try host.nextAction()) |_| {}
        try std.testing.expect(call.result() == .ready);
        try std.testing.expectEqual(@as(usize, 1), calls);
        if (cancel) try host.vowRelease(vow);
        try host.resolverFulfillValue(resolver, .{ .list = &.{ .{ .capability = child }, .{ .capability = child } } }, a);
        var completed: usize = 0;
        while (try host.takeAction()) |action| {
            defer host.freeAction(action);
            try std.testing.expect(!cancel and action == .settled);
            try std.testing.expectEqual(child, action.settled.value.list[0].capability);
            try std.testing.expectEqual(child, action.settled.value.list[1].capability);
            try host.vowRelease(vow);
            completed += 1;
        }
        try std.testing.expectEqual(@as(usize, if (cancel) 0 else 1), completed);
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
        try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(child));
    }
}

test "core host local callback effects preserve public resolver on reply allocation refusal" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var counted: metrics.CountingAllocator = .{ .backing = failing.allocator() };
    var host = support.init(counted.allocator(), @splat(0xa4), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    var resolver: u64 = 0;
    const child = try spawn(&host, Child, .{ .calls = &calls, .resolver = &resolver });
    defer host.releaseCapabilityTerminal(child, null);
    var vow: u64 = 0;
    const parent = try spawn(&host, Parent, .{ .target = child, .vow = &vow, .tell = false });
    defer host.releaseCapabilityTerminal(parent, null);
    const call = try host.callLocalCapability(a, parent, "start", &.{.{ .integer = 1 }}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    const result: driver.Value = .{ .list = &.{ .{ .string = "retained" }, .{ .capability = child }, .{ .capability = child } } };
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, host.resolverFulfillValue(resolver, result, a));
    try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(child));
    failing.fail_index = std.math.maxInt(usize);
    // Exercise the public reply owner's transfer itself, before the resolver
    // witness below exercises queue adoption through the Host consumer.
    const Reply = @TypeOf(host.vows.get(vow).?.owner.owning.destination.public.*);
    var reply: Reply = .{ .producer = .{ .host = &host }, .id = 91 };
    reply.producer.destination = .{ .public = &reply };
    defer reply.deinit();
    try host.reserveActions(1);
    try reply.prepare(result);
    const prepared_pointer = reply.result.prepared.list.ptr;
    const before_publish = counted.allocs;
    reply.publish(.{ .fulfilled = .{ .void = {} } }, .broken);
    try std.testing.expectEqual(prepared_pointer, host.actions.peek().?.settled.value.list.ptr);
    try std.testing.expectEqual(before_publish, counted.allocs);
    const transferred = (try host.takeAction()).?;
    host.freeAction(transferred);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(child));
    try host.resolverFulfillValue(resolver, result, a);
    const pointer = host.actions.peek().?.settled.value.list.ptr;
    const allocations = counted.allocs;
    const action = (try host.takeAction()).?;
    defer host.freeAction(action);
    try std.testing.expectEqual(pointer, action.settled.value.list.ptr);
    try std.testing.expectEqual(allocations, counted.allocs);
    try std.testing.expectEqual(child, action.settled.value.list[1].capability);
    try std.testing.expectEqual(child, action.settled.value.list[2].capability);
    try std.testing.expectEqualStrings("retained", action.settled.value.list[0].string);
    try host.vowRelease(vow);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
}

fn constructorRefusal(failure_index: usize, tell: bool) !bool {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var host = support.init(failing.allocator(), @splat(0xa5), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const child = try spawn(&host, Child, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(child, null);
    var vow: u64 = 0;
    const parent = try spawn(&host, Parent, .{ .target = child, .vow = &vow, .tell = tell });
    defer host.releaseCapabilityTerminal(parent, null);
    const call = try host.callLocalCapability(a, parent, "start", &.{.{ .list = &.{ .{ .string = "exact" }, .{ .capability = child } } }}, 512);
    defer call.deinit();
    failing.fail_index = failing.alloc_index + failure_index;
    _ = host.vat.driveBudgeted(1) catch |err| failed: {
        try std.testing.expectEqual(error.OutOfMemory, err);
        break :failed {};
    };
    failing.fail_index = std.math.maxInt(usize);
    while (try host.takeAction()) |action| {
        defer host.freeAction(action);
        try std.testing.expect(!tell and action == .settled);
        try std.testing.expectEqual(vow, action.settled.vow_id);
        try host.vowRelease(vow);
    }
    if (call.result() == .failed) {
        try std.testing.expectEqualStrings("OutOfMemory", call.result().failed.message);
        try std.testing.expectEqual(@as(usize, 0), calls);
        try std.testing.expectEqual(@as(u64, 0), vow);
    } else {
        try std.testing.expect(call.result() == .ready);
        try std.testing.expectEqual(@as(usize, 1), calls);
    }
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(child));
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), host.vat.local_ingress.pending_turns);
    return failing.has_induced_failure;
}

test "core host local callback effects refuse each constructor allocation without partial effects" {
    for ([_]bool{ false, true }) |tell| {
        var finished = false;
        for (0..128) |index| if (!try constructorRefusal(index, tell)) {
            finished = true;
            break;
        };
        try std.testing.expect(finished);
    }
}

test "core host local callback effects warmed admission charges metadata and overlapping queue custody" {
    var live: metrics.LiveBytesAllocator = .{ .backing = a };
    var counted: metrics.CountingAllocator = .{ .backing = live.allocator() };
    var host = support.init(counted.allocator(), @splat(0xa8), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const child = try spawn(&host, Child, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(child, null);
    for ([_]bool{ false, true }) |tell| {
        var vow: u64 = 0;
        const parent = try spawn(&host, Parent, .{ .target = child, .vow = &vow, .tell = tell });
        defer host.releaseCapabilityTerminal(parent, null);
        for (0..3) |run| {
            const call = try host.callLocalCapability(a, parent, "start", &.{.{ .integer = 1 }}, 512);
            defer call.deinit();
            counted.allocs = 0;
            _ = try host.vat.driveBudgeted(1);
            // The running parent uses the Vat's one cached chunk. Its child
            // needs one overlapping chunk and arena backing, plus metadata.
            // No child Call or fixed reply buffer is acquired.
            if (run == 2) try std.testing.expectEqual(@as(usize, if (tell) 3 else 4), counted.allocs);
            if (!tell) {
                const row = host.vows.get(vow).?;
                const reply = row.owner.owning.destination.public;
                if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 384), @sizeOf(@TypeOf(reply.*)));
            }
            while (try host.takeAction()) |action| {
                defer host.freeAction(action);
                if (action == .settled) try host.vowRelease(vow);
            }
            try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
            try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        }
    }
}

test "core host local callback effects aggregate teardown owns queued deferred and foreign work" {
    for ([_]enum { queued, deferred, foreign }{ .queued, .deferred, .foreign }) |mode| {
        var host = support.init(a, @splat(0xa6), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var exporter = support.init(a, @splat(0xa7), driver.Host.Options.withFrameCap(4096));
        defer exporter.deinit();
        var calls: usize = 0;
        var resolver: u64 = 0;
        const local = try spawn(&host, Child, .{ .calls = &calls, .resolver = if (mode == .deferred) &resolver else null });
        const actor = try exporter.vat.spawn(WireChild, .{ .calls = &calls });
        const wire = try exporter.retainLocalCapability(actor);
        const swiss = try exporter.publishDurableCapability(@splat(0x62), wire);
        const pair = try pairs.openPair(&host, &exporter, "127.0.0.1:7941");
        var fetched: capture.CapturedRef = .{};
        try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = capture.CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const imported = try host.liftCapability(pair.a, try fetched.require());
        const hop = try spawn(&host, Hop, .{ .target = if (mode == .foreign) imported else local });
        var vow: u64 = 0;
        const parent = try spawn(&host, Parent, .{ .target = hop, .vow = &vow, .tell = false });
        const call = try host.callLocalCapability(a, parent, "start", &.{.{ .integer = 1 }}, 512);
        defer call.deinit();
        _ = try host.vat.driveBudgeted(1);
        if (mode != .queued) while (try host.nextAction()) |_| {};
        try std.testing.expectEqual(@as(usize, if (mode == .deferred) 1 else 0), calls);
        try std.testing.expectEqual(@as(usize, if (mode == .foreign) 2 else 1), host.pending_operations);
        // No child reply is settled or released before aggregate destruction.
    }
}
