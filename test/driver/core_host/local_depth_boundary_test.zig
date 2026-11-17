//! The nesting ceiling at the entries that stay inside one Host: a call to a
//! local capability, the reply its handler returns, and a deferred answer a
//! resolver settles. Each is swept across `model.max_value_depth` over every
//! shape (`depth_shapes.zig`) and asserts the path ran when the value is
//! admitted and that a refusal left no call, retain, or resolver consumed.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../../support/depth_shapes.zig");
const support = @import("../../support/core_host.zig");
const h = @import("harness.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver.core;
const allocator = std.testing.allocator;
const reply_bytes: usize = 1 << 20;

const Echo = struct {
    calls: *usize,
    pub fn handle(self: *Echo, turn: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        const values = try args.values();
        defer turn.releaseValues(values);
        self.calls.* += 1;
        return values[0];
    }
};

const Deferred = struct {
    resolver: *u64,
    pub fn handle(self: *Deferred, turn: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        const values = try args.values();
        defer turn.releaseValues(values);
        self.resolver.* = try turn.deferAnswer();
        return .{ .void = {} };
    }
};

fn spawn(host: *driver.Host, comptime B: type, initial: B) !driver.Capability {
    const reservation = try host.reserveFreshCapability(null);
    const actor = try host.vat.spawn(driver.Hosting(B), .{ .inner = initial });
    return host.adoptReservedLocalCapability(reservation, actor);
}

test "a call to a local capability and the reply it returns follow the session's count" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var host = support.init(allocator, @splat(0x91), driver.Host.Options.init(.unchecked, 4096));
        defer host.deinit();
        var calls: usize = 0;
        const target = try spawn(&host, Echo, .{ .calls = &calls });
        defer host.releaseCapabilityTerminal(target, null);
        const values = try shapes.valueArgs(arena.allocator(), depth, shape);
        if (shapes.admitted(shape, depth)) {
            // Admitted at the call, the handler runs and the same value
            // returns as its reply, which the Host copies at the same count.
            const call = try host.callLocalCapability(allocator, target, "echo", values, reply_bytes);
            defer call.deinit();
            try host.vat.drive();
            try std.testing.expectEqual(@as(usize, 1), calls);
            try std.testing.expect(call.result() == .ready);
        } else {
            try std.testing.expectError(error.ValueTooDeep, host.callLocalCapability(allocator, target, "echo", values, reply_bytes));
            try host.vat.drive();
            try std.testing.expectEqual(@as(usize, 0), calls);
            try std.testing.expectEqual(@as(usize, 0), host.vows.count());
            try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        }
    };
}

test "a resolver settling a deferred local answer follows the session's count and stays unconsumed on refusal" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var host = support.init(allocator, @splat(0x92), driver.Host.Options.init(.unchecked, 4096));
        defer host.deinit();
        var resolver: u64 = 0;
        const target = try spawn(&host, Deferred, .{ .resolver = &resolver });
        defer host.releaseCapabilityTerminal(target, null);
        const call = try host.callLocalCapability(allocator, target, "defer", &.{}, reply_bytes);
        defer call.deinit();
        try host.vat.drive();
        try std.testing.expect(call.result() == .pending);
        const values = try shapes.valueArgs(arena.allocator(), depth, shape);
        const result = host.resolverFulfillValue(resolver, values[0], arena.allocator());
        if (shapes.admitted(shape, depth)) {
            try result;
            try std.testing.expect(call.result() == .ready);
            try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
        } else {
            try std.testing.expectError(error.ValueTooDeep, result);
            // The resolver is still live, so a later settle can succeed.
            try std.testing.expect(call.result() == .pending);
            try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
            try host.resolverFulfillValue(resolver, .{ .integer = 1 }, arena.allocator());
            try std.testing.expect(call.result() == .ready);
        }
    };
}

test "resolverFulfill of an owned argument follows the plain-data count and stays unconsumed on refusal" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // `Host.resolverFulfill` takes the owned model, which has no run arm.
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var host = support.init(allocator, @splat(0x93), driver.Host.Options.init(.unchecked, 4096));
        defer host.deinit();
        var resolver: u64 = 0;
        const target = try spawn(&host, Deferred, .{ .resolver = &resolver });
        defer host.releaseCapabilityTerminal(target, null);
        const call = try host.callLocalCapability(allocator, target, "defer", &.{}, reply_bytes);
        defer call.deinit();
        try host.vat.drive();
        try std.testing.expect(call.result() == .pending);
        const args = try shapes.ownedArgs(arena.allocator(), depth, shape);
        const result = host.resolverFulfill(resolver, args[0]);
        if (shapes.admitted(shape, depth)) {
            try result;
            try std.testing.expect(call.result() == .ready);
            try std.testing.expectEqual(@as(usize, 0), host.resolver_index.count());
        } else {
            // The plain-data walk refuses before any settle work, as a depth
            // refusal and not as capability authority.
            try std.testing.expectError(error.ValueTooDeep, result);
            // The resolver is still live, so a later settle can succeed.
            try std.testing.expect(call.result() == .pending);
            try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
            try host.resolverFulfill(resolver, .{ .integer = 1 });
            try std.testing.expect(call.result() == .ready);
        }
    };
}

/// A Vat actor, not a Host capability, so its reply is a `model.Argument`
/// the settlement boundary copies: a list `max_value_depth + 1` deep when asked.
const RawDeep = struct {
    /// Each deep reply stages a tell to this actor first, a turn effect that
    /// commits with the turn.
    counter: ?glowcap.actors.Ref = null,
    pub fn handle(self: *RawDeep, turn: *glowcap.actors.Turn, msg: glowcap.actors.Delivery) !model.Argument {
        if (!msg.is("deep")) return .{ .integer = 5 };
        if (self.counter) |counter| try turn.tell(counter, .{ .verb = "bump" });
        return (try shapes.ownedArgs(turn.arena, model.max_value_depth + 1, .leaf))[0];
    }
};

const Bump = struct {
    count: *usize,
    pub fn handle(self: *Bump, _: *glowcap.actors.Turn, _: glowcap.actors.Delivery) !model.Argument {
        self.count.* += 1;
        return .{ .void = {} };
    }
};

const Hop = struct {
    target: driver.Capability,
    pub fn handle(self: *Hop, turn: *driver.HostTurn, verb: ?[]const u8, args: driver.Args) !driver.Value {
        defer turn.releaseArguments(args);
        return turn.forward(self.target, verb, try args.values());
    }
};

const Outcome = struct {
    fired: bool = false,
    broken: bool = false,
    detail: [32]u8 = undefined,
    detail_len: usize = 0,
    integer: ?i64 = null,

    fn record(ctx: ?*anyopaque, resolution: glowcap.actors.Resolution) void {
        const self: *Outcome = @ptrCast(@alignCast(ctx.?));
        self.fired = true;
        switch (resolution) {
            .broken => |b| {
                self.broken = true;
                self.detail_len = @min(b.detail.len, self.detail.len);
                @memcpy(self.detail[0..self.detail_len], b.detail[0..self.detail_len]);
            },
            .fulfilled => |value| if (value == .integer) {
                self.integer = value.integer;
            },
            else => {},
        }
    }
};

test "a served forward to a local actor whose reply is past the ceiling breaks that answer, keeps the pump and session, and the next call completes" {
    var client = support.init(allocator, @splat(0xD1), h.nextRouteOptions());
    defer client.deinit();
    var server = support.init(allocator, @splat(0xD2), h.nextRouteOptions());
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer h.deinitParked(allocator, &dials);
    const pair = try h.openPair(allocator, &client, &server, "127.0.0.1:7981", &dials);
    const hosts = [_]*driver.Host{ &client, &server };
    const pairs = [_]h.Pair{pair};

    const reservation = try server.reserveFreshCapability(null);
    var bumps: usize = 0;
    const counter = try server.vat.spawn(Bump, .{ .count = &bumps });
    const actor = try server.vat.spawn(RawDeep, .{ .counter = counter });
    const raw = server.adoptReservedLocalCapability(reservation, actor);
    defer server.releaseCapabilityTerminal(raw, null);
    const hop = try spawn(&server, Hop, .{ .target = raw });
    defer server.releaseCapabilityTerminal(hop, null);
    const name = try server.publishDurableCapability(@splat(0x84), hop);
    var found: h.CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, name.slice()), .{ .ctx = &found, .func = h.CapturedRef.record });
    try h.pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    const remote = try client.liftCapability(pair.a, try found.require());
    defer client.releaseCapabilityTerminal(remote, null);

    for ([_]struct { verb: []const u8, broken: bool }{
        .{ .verb = "deep", .broken = true },
        .{ .verb = "ok", .broken = false },
    }) |call| {
        var outcome: Outcome = .{};
        const vow = try client.sendValues(pair.a, remote, call.verb, &.{}, allocator);
        try client.vowOn(vow, .{ .ctx = &outcome, .func = Outcome.record });
        try h.pumpToQuiescence(allocator, &hosts, &pairs, &dials);
        try std.testing.expect(outcome.fired);
        try std.testing.expectEqual(call.broken, outcome.broken);
        if (call.broken) {
            try std.testing.expectEqualStrings("ValueTooDeep", outcome.detail[0..outcome.detail_len]);
            // The staged tell committed with the turn that broke its answer.
            try std.testing.expectEqual(@as(usize, 1), bumps);
        } else try std.testing.expectEqual(@as(?i64, 5), outcome.integer);
        try std.testing.expect(pair.a.served.port.peer.lastAbort() == null);
        try std.testing.expect(pair.b.served.port.peer.lastAbort() == null);
        try std.testing.expect(pair.a.sessionOpen() and pair.b.sessionOpen());
    }
}
