//! The nesting ceiling on every Host entry path, each swept across
//! `model.max_value_depth` at one below, at, and one past, over every shape
//! the path can carry (`depth_shapes.zig`). The authority is the session's
//! count: a container's items sit one level deeper than it, an empty container
//! included, so a leaf may sit at the ceiling and an empty container may not.
//! A failure means a path counts depth another way than the session does, and
//! the session would refuse what the Host admitted or the Host refuse what the
//! session admits. Local settle and reply copy through `copyValue`, the walk
//! `Producer.prepare` and the owned reply path call.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../../support/depth_shapes.zig");
const test_host = @import("../../support/core_host.zig");
const host_pair = @import("../../support/host_pair.zig");

const model = glowcap.ocapn.model;
const core = glowcap.driver.core;
const actors = glowcap.actors;
const allocator = std.testing.allocator;

const LocalActor = struct {
    pub fn handle(_: *LocalActor, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }
};

fn expectDepth(shape: shapes.Shape, depth: usize, result: anytype, comptime refusal: anyerror) !void {
    if (shapes.admitted(shape, depth)) {
        _ = try result;
    } else {
        try std.testing.expectError(refusal, result);
    }
}

/// A session whose handshake is complete, so an admitted send leaves as a frame.
fn openHost(host: *core.Host, partner: *core.Host) !*core.HostSession {
    return (try host_pair.openPair(host, partner, "127.0.0.1:9781")).a;
}

test "lowering for a far send and retaining for a held send follow the session's count" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x81)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x81 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        const values = try shapes.valueArgs(arena.allocator(), depth, shape);
        try expectDepth(shape, depth, host.lowerValues(session, arena.allocator(), values), error.NestingTooDeep);
        try expectDepth(shape, depth, host.retainValueCapabilities(arena.allocator(), values), error.NestingTooDeep);
    };
}

test "lifting a delivery from borrowed views follows the session's count" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        // A refused lift condemns its session, so every trial has its own.
        var host = test_host.init(allocator, @as([32]u8, @splat(0x82)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x82 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        const args = try shapes.viewArgs(arena.allocator(), depth, shape);
        try expectDepth(shape, depth, host.liftValues(session, arena.allocator(), args), error.NestingTooDeep);
    };
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x83)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x83 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        const args = try shapes.ownedArgs(arena.allocator(), depth, shape);
        try expectDepth(shape, depth, host.liftValue(session, arena.allocator(), args[0]), error.NestingTooDeep);
    };
}

test "a send to a far target refuses at the call, with or without a capability beside the value" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| for ([_]bool{ false, true }) |with_capability| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x84)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x84 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        try session.served.port.peer.importObject(7);
        const target = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
        defer host.releaseCapability(target, 1) catch unreachable;
        const chain = try shapes.valueArgs(arena.allocator(), depth, shape);
        const values = if (with_capability) blk: {
            const both = try arena.allocator().alloc(core.Value, 2);
            both[0] = .{ .capability = target };
            both[1] = chain[0];
            break :blk both;
        } else chain;
        const pending = session.pendingOperations();
        const result = host.sendValues(session, target, "poke", values, arena.allocator());
        try expectDepth(shape, depth, result, error.NestingTooDeep);
        if (!shapes.admitted(shape, depth)) try std.testing.expectEqual(pending, session.pendingOperations());
    };
}

fn inlineGive(gift: u8) model.HandoffGive {
    return .{
        .recipient_key = &(@as([32]u8, @splat(0x11))),
        .exporter = .{ .transport = "tcp", .designator = "127.0.0.1:9799", .hints = model.Hints.emptyFalse() },
        .gifter_exporter_session = &(@as([32]u8, @splat(0x22))),
        .gifter_side = &(@as([32]u8, @splat(0x33))),
        .gift_id = &(@as([model.handoff_gift_id_bytes]u8, @splat(gift))),
        .signature = &(@as([64]u8, @splat(0x55))),
    };
}

test "a send to an unsettled promise refuses at the call for every shape and queues nothing" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x85)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x85 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        var give: model.Handoff = .{ .give = inlineGive(0x44) };
        const promise = (try host.liftValue(session, arena.allocator(), .{ .handoff = &give })).capability;
        defer host.releaseCapability(promise, 1) catch unreachable;
        const promise_id = host.capabilities.resolve(promise).?.deferred;
        const queued_before = host.capability_promises.get(promise_id).?.operations.items.len;
        const values = try shapes.valueArgs(arena.allocator(), depth, shape);
        const result = host.queueSendValues(session, promise, "poke", values, arena.allocator());
        try expectDepth(shape, depth, result, error.NestingTooDeep);
        const queued_after = host.capability_promises.get(promise_id).?.operations.items.len;
        try std.testing.expectEqual(queued_before + @intFromBool(shapes.admitted(shape, depth)), queued_after);
    };
}

test "a settled promise stands for its data at the depth the promise sits" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.sweep) |depth| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x86)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x86 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        var give: model.Handoff = .{ .give = inlineGive(0x44) };
        const promise = (try host.liftValue(session, arena.allocator(), .{ .handoff = &give })).capability;
        defer host.releaseCapability(promise, 1) catch unreachable;
        const row = host.capability_promises.getPtr(host.capabilities.resolve(promise).?.deferred).?;
        row.state = .{ .fulfilled_data = .{ .arena = std.heap.ArenaAllocator.init(allocator), .value = .{ .void = {} } } };
        const values = try shapes.valueArgs(arena.allocator(), depth, .leaf);
        // The leaf is the promise: its data lowers where the promise sat.
        const mutable: []core.Value = @constCast(values);
        var cursor: *core.Value = &mutable[0];
        for (0..depth) |_| cursor = @constCast(&cursor.list[0]);
        cursor.* = .{ .capability = promise };
        const lowered = host.lowerValues(session, arena.allocator(), values);
        if (depth <= model.max_value_depth) _ = try lowered else try std.testing.expectError(error.NestingTooDeep, lowered);
    }
}

test "a send that holds a settled promise refuses at the call when the promise's data does not fit where it sits" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Data = enum { leaf, list, strukt, run };
    for ([_]Data{ .leaf, .list, .strukt, .run }) |kind| for (shapes.sweep) |depth| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x88)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x89)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        var give_open: model.Handoff = .{ .give = inlineGive(0x44) };
        const open = (try host.liftValue(session, arena.allocator(), .{ .handoff = &give_open })).capability;
        defer host.releaseCapability(open, 1) catch unreachable;
        var give_settled: model.Handoff = .{ .give = inlineGive(0x45) };
        const settled = (try host.liftValue(session, arena.allocator(), .{ .handoff = &give_settled })).capability;
        defer host.releaseCapability(settled, 1) catch unreachable;
        const inner = [_]core.Value{.{ .void = {} }};
        const entries = [_]core.Value.StructEntry{.{ .key = "k", .value = .{ .void = {} } }};
        const words = [_]i64{1};
        const data: core.Value = switch (kind) {
            .leaf => .{ .void = {} },
            .list => .{ .list = &inner },
            .strukt => .{ .@"struct" = &entries },
            .run => .{ .integers = &words },
        };
        const row = host.capability_promises.getPtr(host.capabilities.resolve(settled).?.deferred).?;
        row.state = .{ .fulfilled_data = .{ .arena = std.heap.ArenaAllocator.init(allocator), .value = data } };
        const values = try shapes.valueArgs(arena.allocator(), depth, .leaf);
        const mutable: []core.Value = @constCast(values);
        var cursor: *core.Value = &mutable[0];
        for (0..depth) |_| cursor = @constCast(&cursor.list[0]);
        cursor.* = .{ .capability = settled };
        // The chain is within the ceiling through depth 64, and a container
        // for data needs room for its items below the promise.
        const fits = if (kind == .leaf) depth <= model.max_value_depth else depth < model.max_value_depth;
        const open_id = host.capabilities.resolve(open).?.deferred;
        const queued_before = host.capability_promises.get(open_id).?.operations.items.len;
        const result = host.queueSendValues(session, open, "poke", values, arena.allocator());
        const queued_after = host.capability_promises.get(open_id).?.operations.items.len;
        if (fits) {
            _ = try result;
            try std.testing.expectEqual(queued_before + 1, queued_after);
            // What the queue accepted lowers later at the same depth.
            _ = try host.lowerValues(session, arena.allocator(), values);
        } else {
            try std.testing.expectError(error.NestingTooDeep, result);
            try std.testing.expectEqual(queued_before, queued_after);
            try std.testing.expectError(error.NestingTooDeep, host.lowerValues(session, arena.allocator(), values));
        }
    };
}

test "a send to a local actor refuses at the call with the Host value walk" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var host = test_host.init(allocator, @as([32]u8, @splat(0x87)), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(allocator, @as([32]u8, @splat(0x87 + 1)), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const session = try openHost(&host, &partner);
        const local = try host.spawn(session, LocalActor, .{});
        defer host.releaseCapability(local, 1) catch unreachable;
        const values = try shapes.valueArgs(arena.allocator(), depth, shape);
        try expectDepth(shape, depth, host.sendApplicationValues(local, "poke", values, arena.allocator()), error.ValueTooDeep);
    };
}

test "the copy, measure and capability walks behind local settle, reply and delivery share one count" {
    const Visitor = struct {
        fn visit(_: void, _: core.Capability) !void {
            return error.UnexpectedCapability;
        }
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        const root = (try shapes.valueArgs(arena.allocator(), depth, shape))[0];
        try expectDepth(shape, depth, core.copyValue(core.Value, arena.allocator(), root), error.ValueTooDeep);
        try expectDepth(shape, depth, core.copyValue(model.Argument, arena.allocator(), root), error.ValueTooDeep);
        try expectDepth(shape, depth, core.valueCopyBytes(&.{root}), error.ValueTooDeep);
        try expectDepth(shape, depth, root.forEachCapability({}, Visitor.visit), error.ValueTooDeep);
    };
}
