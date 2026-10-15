//! Capability projection transactions: bounded recursive shape, exact rollback
//! of every authority kind, and completion/promise failure classification.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const host_pair = @import("../../support/host_pair.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const core = glowcap.driver.core;
const actors = glowcap.actors;

const LocalActor = struct {
    pub fn handle(_: *LocalActor, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }
};

test "remote capability cleanup survives session cancellation and termination" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x65)), .{});
    defer host.deinit();
    var partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x75)), .{});
    defer partner.deinit();
    const session = (try host_pair.openPair(&host, &partner, "127.0.0.1:9765")).a;
    try session.served.port.peer.importObject(7);
    const first = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    try session.served.port.peer.importObject(7);
    const second = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    try std.testing.expectEqual(first.raw(), second.raw());

    try host.beginSessionClose(session, .cancel, 0);
    try std.testing.expectEqual(core.HostSession.LifecyclePhase.cancel_pending, session.lifecyclePhase());
    try host.releaseCapability(first, 1);
    try std.testing.expectEqual(@as(u64, 1), host.capabilities.retainCount(second).?);
    // Cancellation owns wire retirement; application cleanup must not enqueue
    // new GC traffic on the condemned session.
    try std.testing.expect((try session.takeOutbound()) == null);

    try host.progressSessionCloses(1);
    try std.testing.expectEqual(core.HostSession.LifecyclePhase.terminating, session.lifecyclePhase());
    try host.releaseCapability(second, 1);
    try std.testing.expect(host.capabilities.retainCount(second) == null);
    try std.testing.expectError(error.UnknownCapability, host.releaseCapability(second, 1));
}

fn nestedValue(backing: [][1]core.Value, containers: usize) core.Value {
    backing[containers][0] = .{ .void = {} };
    var depth = containers;
    while (depth != 0) {
        depth -= 1;
        backing[depth][0] = .{ .list = &backing[depth + 1] };
    }
    return backing[0][0];
}

fn nestedArgument(backing: [][1]model.Argument, containers: usize) model.Argument {
    backing[containers][0] = .{ .void = {} };
    var depth = containers;
    while (depth != 0) {
        depth -= 1;
        backing[depth][0] = .{ .list = &backing[depth + 1] };
    }
    return backing[0][0];
}

fn inlineGive() model.HandoffGive {
    return .{
        .recipient_key = &(@as([32]u8, @splat(0x11))),
        .exporter = .{
            .transport = "tcp",
            .designator = "127.0.0.1:9799",
            .hints = model.Hints.emptyFalse(),
        },
        .gifter_exporter_session = &(@as([32]u8, @splat(0x22))),
        .gifter_side = &(@as([32]u8, @splat(0x33))),
        .gift_id = &(@as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x44))),
        .signature = &(@as([64]u8, @splat(0x55))),
    };
}

fn receiveHandoff() model.HandoffReceive {
    return .{
        .receiving_session = "session",
        .receiving_side = "side",
        .handoff_count = 0,
        .signed_give = inlineGive(),
        .signature = "receive-signature",
    };
}

test "Host direct lower and lift admit exactly the model depth limit" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x61)), .{});
    defer host.deinit();
    const session = try host_pair.publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9761", &.{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var value_exact: [model.max_value_depth + 1][1]core.Value = undefined;
    _ = try host.lowerValue(
        session,
        arena.allocator(),
        nestedValue(&value_exact, model.max_value_depth),
    );
    var value_over: [model.max_value_depth + 2][1]core.Value = undefined;
    try std.testing.expectError(
        error.NestingTooDeep,
        host.lowerValue(
            session,
            arena.allocator(),
            nestedValue(&value_over, model.max_value_depth + 1),
        ),
    );

    var argument_exact: [model.max_value_depth + 1][1]model.Argument = undefined;
    _ = try host.liftValue(
        session,
        arena.allocator(),
        nestedArgument(&argument_exact, model.max_value_depth),
    );
    var argument_over: [model.max_value_depth + 2][1]model.Argument = undefined;
    try std.testing.expectError(
        error.NestingTooDeep,
        host.liftValue(
            session,
            arena.allocator(),
            nestedArgument(&argument_over, model.max_value_depth + 1),
        ),
    );

    // Lowering and retention bound the child sequence even when it is empty.
    const integer = [_]core.Value{.{ .integer = 7 }};
    for ([_]core.Value{
        .{ .integers = &.{7} }, .{ .list = &integer },
        .{ .integers = &.{} },  .{ .list = &.{} },
    }) |leaf| {
        _ = nestedValue(&value_exact, model.max_value_depth);
        value_exact[model.max_value_depth][0] = leaf;
        try std.testing.expectError(error.NestingTooDeep, host.lowerValue(session, arena.allocator(), value_exact[0][0]));
        try std.testing.expectError(error.NestingTooDeep, host.retainValueCapabilities(arena.allocator(), &value_exact[0]));
        _ = nestedValue(&value_exact, model.max_value_depth - 1);
        value_exact[model.max_value_depth - 1][0] = leaf;
        _ = try host.lowerValue(session, arena.allocator(), value_exact[0][0]);
        try std.testing.expectEqual(@as(usize, 0), (try host.retainValueCapabilities(arena.allocator(), &value_exact[0])).len);
    }
}

test "overdeep lower rolls back preceding Port and Node projections" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x62)), .{});
    defer host.deinit();
    var home_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x72)), .{});
    defer home_partner.deinit();
    var destination_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x73)), .{});
    defer destination_partner.deinit();
    const home = (try host_pair.openPair(&host, &home_partner, "127.0.0.1:9762")).a;
    const destination = (try host_pair.openPair(&host, &destination_partner, "127.0.0.1:9763")).a;
    try home.served.port.peer.importObject(7);
    const remote = try host.liftCapability(home, .{ .far = model.FarRef.object(7) });
    defer host.releaseCapability(remote, 1) catch unreachable;
    const local = try host.spawn(destination, LocalActor, .{});
    defer host.releaseCapability(local, 1) catch unreachable;

    const exports_before = destination.served.port.exports.count();
    const routes_before = host.node.foreign_imports.count();
    const remote_retains_before = host.capabilities.retainCount(remote).?;
    const local_retains_before = host.capabilities.retainCount(local).?;
    var over_backing: [model.max_value_depth + 2][1]core.Value = undefined;
    const values = [_]core.Value{
        .{ .capability = local },
        .{ .capability = remote },
        nestedValue(&over_backing, model.max_value_depth + 1),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.NestingTooDeep,
        host.lowerValues(destination, arena.allocator(), &values),
    );

    try std.testing.expectEqual(exports_before, destination.served.port.exports.count());
    try std.testing.expectEqual(routes_before, host.node.foreign_imports.count());
    // The walk staged a lease on the routed reference before the overdeep
    // value refused it, and the failed transaction gave that retain back.
    try std.testing.expectEqual(remote_retains_before, host.capabilities.retainCount(remote).?);
    try std.testing.expectEqual(local_retains_before, host.capabilities.retainCount(local).?);
    try std.testing.expect(home.served.port.peer.session_state.foreignRouteIdFor(.from(7)) == null);
    try std.testing.expect(destination.served.port.peer.sessionIsOpen());
}

test "a routed reference's staging retain returns when no batch claims it" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x64)), .{});
    defer host.deinit();
    var home_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x74)), .{});
    defer home_partner.deinit();
    var destination_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x75)), .{});
    defer destination_partner.deinit();
    const home = (try host_pair.openPair(&host, &home_partner, "127.0.0.1:9764")).a;
    const destination = (try host_pair.openPair(&host, &destination_partner, "127.0.0.1:9765")).a;
    try home.served.port.peer.importObject(7);
    const remote = try host.liftCapability(home, .{ .far = model.FarRef.object(7) });
    defer host.releaseCapability(remote, 1) catch unreachable;
    const local = try host.spawn(destination, LocalActor, .{});
    defer host.releaseCapability(local, 1) catch unreachable;

    const remote_retains_before = host.capabilities.retainCount(remote).?;
    const local_retains_before = host.capabilities.retainCount(local).?;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lowered = try host.lowerValues(destination, arena.allocator(), &.{
        .{ .capability = local },
        .{ .capability = remote },
    });
    try std.testing.expect(lowered[0].reference == .near);
    try std.testing.expect(lowered[1].reference == .routed);
    // A direct lowering opens no lease window, so the retain the walk took
    // for the routed reference came back at commit. The near reference never
    // took one.
    try std.testing.expectEqual(remote_retains_before, host.capabilities.retainCount(remote).?);
    try std.testing.expectEqual(local_retains_before, host.capabilities.retainCount(local).?);
}

fn rejectedValues(_: void, _: []const core.Value) error{Rejected}!void {
    return error.Rejected;
}

test "direct mixed lift retires references around an inline give failure" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x63)), .{});
    defer host.deinit();
    var partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x74)), .{});
    defer partner.deinit();
    const session = (try host_pair.openPair(&host, &partner, "127.0.0.1:9764")).a;
    try session.served.port.peer.importObject(7);
    try session.served.port.peer.importObject(7);
    var give: model.Handoff = .{ .give = inlineGive() };
    var receive: model.Handoff = .{ .receive = receiveHandoff() };
    const args = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.object(7) } },
        .{ .handoff = &give },
        .{ .handoff = &receive },
        .{ .reference = .{ .far = model.FarRef.object(7) } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.UnsupportedValue,
        host.liftValues(session, arena.allocator(), .fromOwnedSlice(&args)),
    );
    try std.testing.expectEqual(@as(usize, 0), host.capabilities.liveCount());
    try std.testing.expectEqual(@as(u64, 0), session.served.port.peer.session_state.importRefcount(.from(7)));
    try std.testing.expectEqual(@as(usize, 1), host.capability_promises.count());
    var promises = host.capability_promises.valueIterator();
    try std.testing.expect(promises.next().?.abandoned);
}

test "projection callback failure counts inline gives separately from references" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x64)), .{});
    defer host.deinit();
    var partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x75)), .{});
    defer partner.deinit();
    const session = (try host_pair.openPair(&host, &partner, "127.0.0.1:9765")).a;
    try session.served.port.peer.importObject(7);
    try session.served.port.peer.importObject(7);
    var give: model.Handoff = .{ .give = inlineGive() };
    const args = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.object(7) } },
        .{ .handoff = &give },
        .{ .reference = .{ .far = model.FarRef.object(7) } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.Rejected,
        host.projectValues(session, arena.allocator(), .fromOwnedSlice(&args), {}, rejectedValues),
    );
    try std.testing.expectEqual(@as(usize, 0), host.capabilities.liveCount());
    try std.testing.expectEqual(@as(u64, 0), session.served.port.peer.session_state.importRefcount(.from(7)));
}

test "overdeep failed-lift cleanup condemns the source session" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x65)), .{});
    defer host.deinit();
    var partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x76)), .{});
    defer partner.deinit();
    const session = (try host_pair.openPair(&host, &partner, "127.0.0.1:9766")).a;
    try session.served.port.peer.importObject(7);
    try session.served.port.peer.importObject(7);
    var over_backing: [model.max_value_depth + 2][1]model.Argument = undefined;
    const args = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.object(7) } },
        nestedArgument(&over_backing, model.max_value_depth + 1),
        .{ .reference = .{ .far = model.FarRef.object(7) } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.NestingTooDeep,
        host.liftValues(session, arena.allocator(), .fromOwnedSlice(&args)),
    );
    try std.testing.expect(!session.served.port.peer.sessionIsOpen());
}

test "allocation failure cleanup stays bounded over an overdeep remainder" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x68)), .{});
    defer host.deinit();
    var partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x78)), .{});
    defer partner.deinit();
    const session = (try host_pair.openPair(&host, &partner, "127.0.0.1:9769")).a;
    try session.served.port.peer.importObject(7);
    var over_backing: [model.max_value_depth + 2][1]model.Argument = undefined;
    const args = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.object(7) } },
        nestedArgument(&over_backing, model.max_value_depth + 1),
    };
    // Fail only the representation arena. Cleanup retains the Host allocator
    // it needs to retire the enumerable reference before the bounded scan
    // reaches the overdeep remainder and transfers final ownership to teardown.
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        host.liftValues(session, failing.allocator(), .fromOwnedSlice(&args)),
    );
    try std.testing.expectEqual(@as(usize, 0), host.capabilities.liveCount());
    try std.testing.expectEqual(@as(u64, 0), session.served.port.peer.session_state.importRefcount(.from(7)));
    try std.testing.expect(!session.served.port.peer.sessionIsOpen());
}

fn identityValue(_: void, value: core.Value) !core.Value {
    return value;
}

test "completion projection preserves owned data after source closure and reports refusal" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x66)), .{});
    defer host.deinit();
    const action: core.HostAction = .{ .settled = .{ .peer_handle = engine.PeerHandle.from(999), .vow_id = 41, .value = .{ .void = {} } } };
    const completed = host.projectCompletion(action, {}, identityValue);
    try std.testing.expect(completed == .settled);
    try std.testing.expectEqual(@as(u64, 41), completed.settled.vow_id);
    const Refuse = struct {
        fn project(_: void, _: core.Value) !core.Value {
            return error.Refused;
        }
    };
    const refused = host.projectCompletion(action, {}, Refuse.project);
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqual(@as(u64, 41), refused.failed.vow_id);
    try std.testing.expectEqual(core.VowFailure.broken, refused.failed.failure);
    try std.testing.expectEqualStrings("resolution value could not be projected", refused.failed.message);
}

test "unresolved-promise clone rejects overdepth without retain or queue mutation" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x67)), .{});
    defer host.deinit();
    const session = try host_pair.publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9768", &.{});
    var give: model.Handoff = .{ .give = inlineGive() };
    var lift_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer lift_arena.deinit();
    const promise_value = try host.liftValue(
        session,
        lift_arena.allocator(),
        .{ .handoff = &give },
    );
    const promise = promise_value.capability;
    defer host.releaseCapability(promise, 1) catch unreachable;
    const promise_id = host.capabilities.resolve(promise).?.deferred;
    const argument = try host.spawn(session, LocalActor, .{});
    defer host.releaseCapability(argument, 1) catch unreachable;
    const retains_before = host.capabilities.retainCount(argument).?;
    const queued_before = host.capability_promises.get(promise_id).?.operations.items.len;
    var over_backing: [model.max_value_depth + 2][1]core.Value = undefined;
    const values = [_]core.Value{
        .{ .capability = argument },
        nestedValue(&over_backing, model.max_value_depth + 1),
    };
    var call_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena.deinit();

    try std.testing.expectError(
        error.NestingTooDeep,
        host.queueSendValues(session, promise, "poke", &values, call_arena.allocator()),
    );
    try std.testing.expectEqual(retains_before, host.capabilities.retainCount(argument).?);
    try std.testing.expectEqual(queued_before, host.capability_promises.get(promise_id).?.operations.items.len);

    const integer = [_]core.Value{.{ .integer = 7 }};
    for ([_]core.Value{
        .{ .integers = &.{7} }, .{ .list = &integer },
        .{ .integers = &.{} },  .{ .list = &.{} },
    }) |leaf| {
        _ = nestedValue(&over_backing, model.max_value_depth);
        over_backing[model.max_value_depth][0] = leaf;
        try std.testing.expectError(error.NestingTooDeep, host.queueSendValues(
            session,
            promise,
            "poke",
            &.{ .{ .capability = argument }, over_backing[0][0] },
            call_arena.allocator(),
        ));
        try std.testing.expectEqual(retains_before, host.capabilities.retainCount(argument).?);
        try std.testing.expectEqual(queued_before, host.capability_promises.get(promise_id).?.operations.items.len);
    }
}
