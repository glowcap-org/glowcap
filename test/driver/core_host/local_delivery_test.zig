//! Owning local calls preserve exact authority on the shared eventual queue.
const std = @import("std");
const glowcap = @import("glowcap");
const driver = glowcap.driver.core;
const actors = glowcap.actors;
const support = @import("../../support/core_host.zig");
const a = std.testing.allocator;
const metrics = @import("../../support/alloc_metrics.zig");
const pairs = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;

const Echo = struct {
    calls: *usize,
    pub fn handle(self: *Echo, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        try std.testing.expect(turn.session == null);
        try std.testing.expect(turn.turn.origin == .eventual);
        self.calls.* += 1;
        return arg_values[0];
    }
};

fn spawn(host: *driver.Host, comptime B: type, initial: B) !driver.Capability {
    const reservation = try host.reserveFreshCapability(null);
    const actor = try host.vat.spawn(driver.Hosting(B), .{ .inner = initial });
    return host.adoptReservedLocalCapability(reservation, actor);
}

test "core host owning local call preserves nested repeated capability identities" {
    var host = support.init(a, @splat(0x61), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const ref = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(ref, null);
    const args = [_]driver.Value{.{ .list = &.{ .{ .string = "kept" }, .{ .capability = ref }, .{ .@"struct" = &.{.{ .key = "same", .value = .{ .capability = ref } }} } } }};
    const call = try host.callLocalCapability(a, ref, "echo", &args, 4096);
    defer call.deinit();
    try std.testing.expect(call.result() == .pending);
    try std.testing.expectEqual(@as(usize, 0), calls);
    try host.vat.drive();
    const reply = call.result().ready.list;
    try std.testing.expectEqualStrings("kept", reply[0].string);
    try std.testing.expectEqual(ref, reply[1].capability);
    try std.testing.expectEqual(ref, reply[2].@"struct"[0].value.capability);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
}

test "core host owning local observer cancellation frees caller input before the effect runs" {
    var host = support.init(a, @splat(0x62), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const target = try spawn(&host, Echo, .{ .calls = &calls });
    var input = std.heap.ArenaAllocator.init(a);
    const text = try input.allocator().dupe(u8, "kept");
    const values = try input.allocator().alloc(driver.Value, 1);
    values[0] = .{ .list = &.{ .{ .string = text }, .{ .capability = target } } };
    const call = try host.callLocalCapability(input.allocator(), target, "echo", values, 4096);
    call.deinit();
    input.deinit();
    host.releaseCapabilityTerminal(target, null);
    try std.testing.expectEqual(@as(usize, 1), host.pending_operations);
    try host.vat.drive();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expect(host.capabilities.retainCount(target) == null);
}

test "core host owning local delivery preserves imported identities and refuses retired homes" {
    for ([_]enum { live, queued, deferred }{ .live, .queued, .deferred }) |retirement| {
        var host = support.init(a, @splat(0x83), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var exporter = support.init(a, @splat(0x84), driver.Host.Options.withFrameCap(4096));
        defer exporter.deinit();
        var remote_calls: usize = 0;
        const published = try spawn(&exporter, Echo, .{ .calls = &remote_calls });
        defer exporter.releaseCapabilityTerminal(published, null);
        const swiss = try exporter.publishDurableCapability(@splat(0x43), published);
        const pair = try pairs.openPair(&host, &exporter, "127.0.0.1:7921");
        var fetched: CapturedRef = .{};
        try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const imported = try host.liftCapability(pair.a, try fetched.require());
        defer host.releaseCapabilityTerminal(imported, null);
        var calls: usize = 0;
        var resolver: u64 = 0;
        const target = if (retirement == .deferred)
            try spawn(&host, Deferred, .{ .resolver = &resolver })
        else
            try spawn(&host, Echo, .{ .calls = &calls });
        defer host.releaseCapabilityTerminal(target, null);
        const value: driver.Value = .{ .list = &.{ .{ .capability = imported }, .{ .@"struct" = &.{.{ .key = "same", .value = .{ .capability = imported } }} } } };
        const call = try host.callLocalCapability(a, target, "echo", &.{value}, 4096);
        defer call.deinit();
        if (retirement == .queued) try host.releaseSession(pair.a);
        while (try host.nextAction()) |_| {}
        switch (retirement) {
            .live => {
                const reply = call.result().ready.list;
                try std.testing.expectEqual(imported, reply[0].capability);
                try std.testing.expectEqual(imported, reply[1].@"struct"[0].value.capability);
                try std.testing.expectEqual(@as(usize, 1), calls);
                try std.testing.expectEqual(@as(?u64, 3), host.capabilities.retainCount(imported));
            },
            .queued => {
                try std.testing.expect(call.result() == .failed);
                try std.testing.expectEqual(@as(usize, 0), calls);
                try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(imported));
            },
            .deferred => {
                try std.testing.expect(call.result() == .pending);
                try host.releaseSession(pair.a);
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                try std.testing.expectError(error.UnknownCapability, host.resolverFulfillValue(resolver, value, arena.allocator()));
                try std.testing.expect(call.result() == .pending);
                try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
                try host.resolverFulfillValue(resolver, .{ .integer = 91 }, arena.allocator());
                try std.testing.expectEqual(@as(i64, 91), call.result().ready.integer);
                try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(imported));
            },
        }
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
        try std.testing.expectEqual(@as(usize, 0), remote_calls);
    }
}

const Plain = struct {
    pub fn handle(_: *Plain, _: *actors.Turn, _: actors.Delivery) !glowcap.ocapn.model.Argument {
        return error.MustNotRun;
    }
};

test "core host owning local refusal keeps effect and capability custody atomic" {
    var host = support.init(a, @splat(0x63), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const ref = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(ref, null);
    host.vat.queue_limits.max_pending_turns = 0;
    try std.testing.expectError(error.ResourceExhausted, host.callLocalCapability(a, ref, "echo", &.{.{ .integer = 1 }}, 4096));
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(ref));
    host.vat.queue_limits.max_pending_turns = 4096;
    const plain = try host.vat.spawn(Plain, .{});
    const cap = try host.retainLocalCapability(plain);
    defer host.releaseCapabilityTerminal(cap, null);
    const call = try host.callLocalCapability(a, cap, "echo", &.{}, 4096);
    defer call.deinit();
    try host.vat.drive();
    try std.testing.expectEqualStrings("UnsupportedDelivery", call.result().failed.message);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), calls);
}

const Deferred = struct {
    resolver: *u64,
    fail: bool = false,
    pub fn handle(self: *Deferred, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.resolver.* = try turn.deferAnswer();
        if (self.fail) return error.Refused;
        return .{ .void = {} };
    }
};

const Forwarder = struct {
    target: driver.Capability,
    fail: bool = false,

    pub fn handle(self: *Forwarder, turn: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        try std.testing.expectEqual(@as(usize, 1), turn.host.vows.count());
        const reply = try turn.forward(self.target, verb, arg_values);
        try std.testing.expectEqual(@as(usize, 1), turn.host.vows.count());
        if (self.fail) return error.Refused;
        return reply;
    }
};

test "core host owning local forwarding shares one exact reply owner through queued hops" {
    var host = support.init(a, @splat(0x77), .{ .host_work_quantum = 1 });
    defer host.deinit();
    var calls: usize = 0;
    const target = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(target, null);
    const first = try spawn(&host, Forwarder, .{ .target = target });
    defer host.releaseCapabilityTerminal(first, null);
    const second = try spawn(&host, Forwarder, .{ .target = first });
    defer host.releaseCapabilityTerminal(second, null);
    const call = try host.callLocalCapability(a, second, "echo", &.{.{ .list = &.{ .{ .capability = target }, .{ .capability = target } } }}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqual(target, call.result().ready.list[0].capability);
    try std.testing.expectEqual(target, call.result().ready.list[1].capability);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
}

test "core host owning local refused forwarding retracts the staged target before its effect" {
    var host = support.init(a, @splat(0x78), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const target = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(target, null);
    const front = try spawn(&host, Forwarder, .{ .target = target, .fail = true });
    defer host.releaseCapabilityTerminal(front, null);
    const call = try host.callLocalCapability(a, front, "echo", &.{.{ .capability = target }}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqualStrings("Refused", call.result().failed.message);
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(target));
}

test "core host owning local forwarded deferral retains the original bounded result for retry" {
    var host = support.init(a, @splat(0x79), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var resolver: u64 = 0;
    const target = try spawn(&host, Deferred, .{ .resolver = &resolver });
    defer host.releaseCapabilityTerminal(target, null);
    const front = try spawn(&host, Forwarder, .{ .target = target });
    defer host.releaseCapabilityTerminal(front, null);
    const call = try host.callLocalCapability(a, front, "wait", &.{}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expect(call.result() == .pending);
    try std.testing.expectEqual(@as(usize, 1), host.pending_operations);
    const too_large: [1024]u8 = @splat('x');
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.ReplyCapacity, host.resolverFulfillValue(resolver, .{ .string = &too_large }, arena.allocator()));
    try host.resolverFulfillValue(resolver, .{ .capability = target }, arena.allocator());
    try std.testing.expectEqual(target, call.result().ready.capability);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
}

test "core host owning local deferred reply refuses preparation and retries the same resolver" {
    var host = support.init(a, @splat(0x64), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var resolver: u64 = 0;
    const ref = try spawn(&host, Deferred, .{ .resolver = &resolver });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "wait", &.{}, 512);
    defer call.deinit();
    try host.vat.drive();
    try std.testing.expect(call.result() == .pending);
    try std.testing.expectEqual(@as(usize, 1), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
    const large: [1024]u8 = @splat('x');
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.ReplyCapacity, host.resolverFulfillValue(resolver, .{ .string = &large }, arena.allocator()));
    try std.testing.expect(call.result() == .pending);
    try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
    try host.resolverFulfillValue(resolver, .{ .list = &.{ .{ .capability = ref }, .{ .capability = ref } } }, arena.allocator());
    try std.testing.expectEqual(ref, call.result().ready.list[0].capability);
    try std.testing.expectEqual(ref, call.result().ready.list[1].capability);
    try std.testing.expectError(error.AlreadySettled, host.resolverFulfillValue(resolver, .{ .void = {} }, arena.allocator()));
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
}

test "core host owning local canceled deferred observer leaves physical work until settlement" {
    var host = support.init(a, @splat(0x65), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var resolver: u64 = 0;
    const ref = try spawn(&host, Deferred, .{ .resolver = &resolver });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "wait", &.{}, 512);
    try host.vat.drive();
    call.deinit();
    try std.testing.expectEqual(@as(usize, 1), host.pending_operations);
    try host.resolverFulfill(resolver, .{ .integer = 91 });
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
}

test "core host owning local failed deferred turn retracts its resolver and prepared reply" {
    var host = support.init(a, @splat(0x66), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var resolver: u64 = 0;
    const ref = try spawn(&host, Deferred, .{ .resolver = &resolver, .fail = true });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "wait", &.{}, 512);
    defer call.deinit();
    try host.vat.drive();
    try std.testing.expectEqualStrings("Refused", call.result().failed.message);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(@as(usize, 0), host.vat.listeners.count());
}

const Outer = struct {
    call: *driver.Host.Call,
    pub fn handle(self: *Outer, turn: *actors.Turn, _: actors.Delivery) !glowcap.ocapn.model.Argument {
        try turn.vat.drive();
        try std.testing.expect(self.call.result() == .pending);
        return error.Refused;
    }
};

test "core host owning local nested execution cannot publish before the outer turn commits" {
    var host = support.init(a, @splat(0x67), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const ref = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "echo", &.{.{ .capability = ref }}, 512);
    defer call.deinit();
    const outer = try host.vat.spawn(Outer, .{ .call = call });
    try std.testing.expectError(error.Refused, host.vat.near(outer, .{ .verb = "drive" }));
    try std.testing.expectEqualStrings("Refused", call.result().failed.message);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(ref));
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 1), calls);
}

const Becoming = struct {
    text: []u8,
    pub fn handle(self: *Becoming, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        const next = try turn.turn.vat.allocator.dupe(u8, "after");
        try turn.turn.become(driver.Hosting(Becoming), .{ .inner = .{ .text = next } });
        return .{ .string = self.text };
    }
    pub fn deinit(self: *Becoming, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

test "core host owning local reply is captured before become retires the borrowed state" {
    var host = support.init(a, @splat(0x68), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    const text = try a.dupe(u8, "before");
    const ref = try spawn(&host, Becoming, .{ .text = text });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "become", &.{}, 512);
    defer call.deinit();
    try host.vat.drive();
    try std.testing.expectEqualStrings("before", call.result().ready.string);
    try std.testing.expect(call.result().ready.string.ptr != text.ptr);
}

fn deferredAllocationRefusal(allocator: std.mem.Allocator, fail: bool) !void {
    var host = support.init(allocator, @splat(0x69), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var resolver: u64 = 0;
    const ref = try spawn(&host, Deferred, .{ .resolver = &resolver, .fail = fail });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(allocator, ref, "wait", &.{}, 512);
    defer call.deinit();
    try host.vat.drive();
    if (call.result() == .failed) {
        if (std.mem.eql(u8, call.result().failed.message, "OutOfMemory")) return error.OutOfMemory;
        try std.testing.expect(fail);
        try std.testing.expectEqualStrings("Refused", call.result().failed.message);
        try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        return;
    }
    try host.resolverFulfill(resolver, .{ .integer = 91 });
    try std.testing.expectEqual(@as(i64, 91), call.result().ready.integer);
}

test "core host owning local deferred allocation refusals release every producer and forward reservation" {
    try std.testing.checkAllAllocationFailures(a, deferredAllocationRefusal, .{false});
    try std.testing.checkAllAllocationFailures(a, deferredAllocationRefusal, .{true});
}

test "core host owning local public progress respects its quantum and wakes remaining work" {
    var host = support.init(a, @splat(0x70), .{ .host_work_quantum = 1 });
    defer host.deinit();
    var calls: usize = 0;
    const ref = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(ref, null);
    const first = try host.callLocalCapability(a, ref, "echo", &.{.{ .integer = 1 }}, 512);
    defer first.deinit();
    const second = try host.callLocalCapability(a, ref, "echo", &.{.{ .integer = 2 }}, 512);
    defer second.deinit();
    const action = (try host.nextAction()).?;
    try std.testing.expect(action == .resume_work);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(first.result() == .ready and second.result() == .pending);
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqual(@as(i64, 2), second.result().ready.integer);
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "core host owning local finish preserves already admitted deferral and refuses new calls" {
    var host = support.init(a, @splat(0x71), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var resolver: u64 = 0;
    const ref = try spawn(&host, Deferred, .{ .resolver = &resolver });
    defer host.releaseCapabilityTerminal(ref, null);
    const call = try host.callLocalCapability(a, ref, "wait", &.{}, 512);
    defer call.deinit();
    host.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectError(error.HostClosing, host.callLocalCapability(a, ref, "wait", &.{}, 512));
    try host.progressClose(0);
    try std.testing.expect(resolver != 0);
    try std.testing.expect(call.result() == .pending);
    try std.testing.expectEqual(driver.Host.LifecyclePhase.finishing, host.lifecyclePhase());
    try host.resolverFulfill(resolver, .{ .integer = 91 });
    try host.progressClose(0);
    try std.testing.expectEqual(@as(i64, 91), call.result().ready.integer);
    try std.testing.expectEqual(driver.Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core host retained child allocation refusal preserves parent custody for retry" {
    for (0..128) |failure_index| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var host = support.init(failing.allocator(), @splat(0x75), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var calls: usize = 0;
        const ref = try spawn(&host, Echo, .{ .calls = &calls });
        defer host.releaseCapabilityTerminal(ref, null);
        var parent = try host.admitPendingWork();
        defer parent.complete();
        host.beginClose(.{ .finish = .unbounded }, 0);
        failing.fail_index = failing.alloc_index + failure_index;
        const attempt = parent.call(failing.allocator(), ref, "echo", &.{.{ .list = &.{ .{ .string = "kept" }, .{ .capability = ref } } }}, 512);
        const call = if (attempt) |value| value else |err| retry: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), host.pending_operations);
            try std.testing.expectEqual(@as(usize, 0), host.vows.count());
            try std.testing.expectEqual(@as(usize, 0), calls);
            try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(ref));
            try std.testing.expectEqual(@as(usize, 0), host.vat.local_ingress.pending_turns);
            failing.fail_index = std.math.maxInt(usize);
            break :retry try parent.call(failing.allocator(), ref, "echo", &.{.{ .integer = 91 }}, 512);
        };
        defer call.deinit();
        // Constructor refusals, rather than callback failures, are the sweep.
        failing.fail_index = std.math.maxInt(usize);
        try host.vat.drive();
        try std.testing.expect(call.result() == .ready);
        try std.testing.expectEqual(@as(usize, 1), calls);
        try std.testing.expectEqual(@as(usize, 1), host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        if (!failing.has_induced_failure) return;
    }
    return error.AllocationSweepDidNotComplete;
}

test "core host owning local cancellation retires queued and deferred work without late invocation" {
    for ([_]bool{ false, true }) |deferred| {
        var host = support.init(a, @splat(0x72), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var resolver: u64 = 0;
        const ref = try spawn(&host, Deferred, .{ .resolver = &resolver });
        defer host.releaseCapabilityTerminal(ref, null);
        const call = try host.callLocalCapability(a, ref, "wait", &.{}, 512);
        defer call.deinit();
        if (deferred) while (try host.nextAction()) |_| {};
        host.beginClose(.cancel, 0);
        try host.progressClose(0);
        try std.testing.expect(call.result() == .failed);
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
        try std.testing.expectEqual(@as(usize, 0), host.vows.count());
        if (!deferred) try std.testing.expectEqual(@as(u64, 0), resolver);
        try std.testing.expectEqual(driver.Host.LifecyclePhase.closed, host.lifecyclePhase());
    }
}

test "core host owning local caller allocations stay separate from queued input and forwarding" {
    var live: metrics.LiveBytesAllocator = .{ .backing = a };
    var count: metrics.CountingAllocator = .{ .backing = live.allocator() };
    var host = support.init(a, @splat(0x80), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const target = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(target, null);
    const front = try spawn(&host, Forwarder, .{ .target = target });
    defer host.releaseCapabilityTerminal(front, null);
    for ([_]usize{ 512, 4096 }) |reply_bytes| {
        count.allocs = 0;
        const call = try host.callLocalCapability(count.allocator(), front, "echo", &.{.{ .list = &.{ .{ .string = "kept" }, .{ .capability = target }, .{ .capability = target } } }}, reply_bytes);
        try std.testing.expectEqual(@as(usize, 2), count.allocs);
        try std.testing.expectEqual(try driver.Host.Call.sizeBound(reply_bytes), live.liveBytes());
        while (try host.nextAction()) |_| {}
        try std.testing.expectEqual(target, call.result().ready.list[1].capability);
        try std.testing.expectEqual(@as(usize, 2), count.allocs);
        try std.testing.expectEqual(try driver.Host.Call.sizeBound(reply_bytes), live.liveBytes());
        call.deinit();
        try std.testing.expectEqual(@as(u64, 0), live.liveBytes());
    }
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 328), (try driver.Host.Call.sizeBound(1)) - 1);
}

test "core host owning local warmed custody allocates only its producer and vow row" {
    var live: metrics.LiveBytesAllocator = .{ .backing = a };
    var counted: metrics.CountingAllocator = .{ .backing = live.allocator() };
    var host = support.init(counted.allocator(), @splat(0x81), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const target = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(target, null);
    const nested: driver.Value = .{ .list = &.{ .{ .string = "kept" }, .{ .capability = target }, .{ .capability = target } } };
    const warm = try host.callLocalCapability(a, target, "echo", &.{nested}, 4096);
    while (try host.nextAction()) |_| {}
    warm.deinit();
    for ([_]driver.Value{ .{ .integer = 91 }, nested }) |value| {
        const before = live.liveBytes();
        counted.allocs = 0;
        const call = try host.callLocalCapability(a, target, "echo", &.{value}, 4096);
        const Row = @TypeOf(host.vows.get(0).?.*);
        const Producer = @TypeOf(host.vows.get(0).?.owner.owning.*);
        if (@sizeOf(usize) == 8) {
            // The row's watching promise (ADR-0068) is an optional id, and
            // its held completion is a value with its arena state or a
            // failure with its message, under one tag. Whether the row keeps
            // that completion's retains shares the flag bytes.
            try std.testing.expectEqual(@as(usize, 240), @sizeOf(Row));
            try std.testing.expectEqual(@as(usize, 312), @sizeOf(Producer));
        }
        try std.testing.expectEqual(@as(usize, 2), counted.allocs);
        try std.testing.expectEqual(before + @sizeOf(Row) + @sizeOf(Producer), live.liveBytes());
        while (try host.nextAction()) |_| {}
        try std.testing.expect(call.result() == .ready);
        try std.testing.expectEqual(before, live.liveBytes());
        call.deinit();
        try std.testing.expectEqual(before, live.liveBytes());
        try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(target));
    }
}

test "core host owning local reply uses its value tree as the capability receipt" {
    var host = support.init(a, @splat(0x82), driver.Host.Options.withFrameCap(4096));
    defer host.deinit();
    var calls: usize = 0;
    const ref = try spawn(&host, Echo, .{ .calls = &calls });
    defer host.releaseCapabilityTerminal(ref, null);
    // Exactly two inline capability leaves fit. A parallel retain inventory
    // would exhaust this backing despite the complete reply already fitting.
    const call = try host.callLocalCapability(a, ref, "echo", &.{.{ .list = &.{ .{ .capability = ref }, .{ .capability = ref } } }}, 2 * @sizeOf(driver.Value));
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expect(call.result() == .ready);
    try std.testing.expectEqual(ref, call.result().ready.list[0].capability);
    try std.testing.expectEqual(ref, call.result().ready.list[1].capability);
    try std.testing.expectEqual(@as(?u64, 3), host.capabilities.retainCount(ref));
}

const RequestedBytes = struct {
    bytes: usize = 0,
    pub fn include(self: *@This(), len: usize, _: usize, count: usize) !void {
        self.bytes = try std.math.add(usize, self.bytes, try std.math.mul(usize, len, count));
    }
};

test "core host owning local value copy demand includes every heterogeneous leaf and spine" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var traffic: metrics.AllocationTraffic(RequestedBytes) = .{ .backing = arena.allocator() };
    const input = [_]driver.Value{.{ .@"struct" = &.{
        .{ .key = "label", .value = .{ .tagged = .{ .tag = "tag", .value = &.{ .{ .bytes = "bytes" }, .{ .string = "text" }, .{ .set = &.{.{ .symbol = "symbol" }} } } } } },
        .{ .key = "number", .value = .{ .big_integer = .{ .negative = true, .digits = "12345678901234567890" } } },
        .{ .key = "failure", .value = .{ .@"error" = .{ .message = "diagnostic" } } },
    } }};
    const copy = try traffic.allocator().alloc(driver.Value, input.len);
    for (copy, input) |*out, value| out.* = try driver.copyValue(driver.Value, traffic.allocator(), value);
    try std.testing.expectEqual(try driver.valueCopyBytes(&input), traffic.demand.bytes);
    try std.testing.expectEqualDeep(input[0], copy[0]);
    try std.testing.expect(copy[0].@"struct"[0].key.ptr != input[0].@"struct"[0].key.ptr);
}
