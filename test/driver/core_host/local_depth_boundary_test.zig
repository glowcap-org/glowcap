//! The nesting ceiling at the entries that stay inside one Host: a call to a
//! local capability, the reply its handler returns, and a deferred answer a
//! resolver settles. Each is swept across `model.max_value_depth` over every
//! shape (`depth_shapes.zig`) and asserts the path ran when the value is
//! admitted and that a refusal left no call, retain, or resolver consumed.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../../support/depth_shapes.zig");
const support = @import("../../support/core_host.zig");

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
            // The plain-data predicate refuses before any settle work.
            try std.testing.expectError(error.ForeignArgument, result);
            // The resolver is still live, so a later settle can succeed.
            try std.testing.expect(call.result() == .pending);
            try std.testing.expectEqual(@as(usize, 1), host.resolver_index.count());
            try host.resolverFulfill(resolver, .{ .integer = 1 });
            try std.testing.expect(call.result() == .ready);
        }
    };
}
