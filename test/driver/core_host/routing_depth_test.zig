//! Raw Host routing validates one bounded Argument tree against the resolved
//! destination before any vow, operation, or route consequence can begin.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const host_pair = @import("../../support/host_pair.zig");

const model = glowcap.ocapn.model;
const core = glowcap.driver.core;
const actors = glowcap.actors;

const LocalActor = struct {
    pub fn handle(_: *LocalActor, _: *actors.Turn, _: actors.Message) !model.Argument {
        return .{ .void = {} };
    }
};

fn nestedArgument(
    backing: [][1]model.Argument,
    containers: usize,
    leaf: model.Argument,
) model.Argument {
    backing[containers][0] = leaf;
    var depth = containers;
    while (depth != 0) {
        depth -= 1;
        backing[depth][0] = .{ .list = &backing[depth + 1] };
    }
    return backing[0][0];
}

test "raw routing admits the depth limit and refuses the next node without mutation" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x69)), .{});
    defer host.deinit();
    var source_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x79)), .{});
    defer source_partner.deinit();
    var destination_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x7a)), .{});
    defer destination_partner.deinit();
    const source = (try host_pair.openPair(&host, &source_partner, "127.0.0.1:9770")).a;
    const destination = (try host_pair.openPair(&host, &destination_partner, "127.0.0.1:9771")).a;

    try destination.served.port.peer.importObject(7);
    const target = try host.node.enrollForeign(
        destination.peer_handle,
        .{ .far = model.FarRef.object(7) },
    );
    var exact_backing: [model.max_value_depth + 1][1]model.Argument = undefined;
    const exact = nestedArgument(
        &exact_backing,
        model.max_value_depth,
        .{ .reference = .{ .far = model.FarRef.object(7) } },
    );
    const routed = try host.routeSend(source, target, &.{exact});
    try std.testing.expectEqual(destination, routed.session);

    const source_pending = source.pendingOperations();
    const destination_pending = destination.pendingOperations();
    const host_pending = host.pending_operations;
    const vows = host.vows.count();
    const next_vow = host.next_vow;
    const routes = host.node.foreign_imports.count();
    var over_backing: [model.max_value_depth + 2][1]model.Argument = undefined;
    const over = nestedArgument(
        &over_backing,
        model.max_value_depth + 1,
        .{ .void = {} },
    );
    try std.testing.expectError(
        error.NestingTooDeep,
        host.routeSend(source, target, &.{over}),
    );

    try std.testing.expect(source.served.port.peer.sessionIsOpen());
    try std.testing.expect(destination.served.port.peer.sessionIsOpen());
    try std.testing.expectEqual(source_pending, source.pendingOperations());
    try std.testing.expectEqual(destination_pending, destination.pendingOperations());
    try std.testing.expectEqual(host_pending, host.pending_operations);
    try std.testing.expectEqual(vows, host.vows.count());
    try std.testing.expectEqual(next_vow, host.next_vow);
    try std.testing.expectEqual(routes, host.node.foreign_imports.count());

    const retried = try host.routeSend(
        source,
        target,
        &.{.{ .reference = .{ .far = model.FarRef.object(7) } }},
    );
    try std.testing.expectEqual(destination, retried.session);
}

test "turn routing shares the bounded raw-argument policy" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x6a)), .{});
    defer host.deinit();
    var partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x7b)), .{});
    defer partner.deinit();
    const session = (try host_pair.openPair(&host, &partner, "127.0.0.1:9772")).a;
    const actor = try session.served.publish(&session.host.vat, "target", LocalActor, .{});
    const capability = try host.liftCapability(session, actor.nearRef());
    defer host.releaseCapability(capability, 1) catch unreachable;
    var over_backing: [model.max_value_depth + 2][1]model.Argument = undefined;
    const over = nestedArgument(
        &over_backing,
        model.max_value_depth + 1,
        .{ .void = {} },
    );
    const pending = session.pendingOperations();
    const vows = host.vows.count();

    try std.testing.expectError(
        error.NestingTooDeep,
        host.routeTurnTarget(session, actor.nearRef(), &.{over}),
    );
    try std.testing.expectError(
        error.NestingTooDeep,
        host.routeTurnCapability(session, capability, &.{over}),
    );
    try std.testing.expectEqual(pending, session.pendingOperations());
    try std.testing.expectEqual(vows, host.vows.count());
    try std.testing.expect(session.served.port.peer.sessionIsOpen());
    _ = try host.routeTurnCapability(session, capability, &.{});
}

test "near raw routing refuses a foreign argument and accepts its own import" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x6b)), .{});
    defer host.deinit();
    var source_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x7c)), .{});
    defer source_partner.deinit();
    var foreign_partner = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x7d)), .{});
    defer foreign_partner.deinit();
    const source = (try host_pair.openPair(&host, &source_partner, "127.0.0.1:9773")).a;
    const foreign = (try host_pair.openPair(&host, &foreign_partner, "127.0.0.1:9774")).a;
    const actor = try source.served.publish(&source.host.vat, "target", LocalActor, .{});

    try foreign.served.port.peer.importObject(8);
    const foreign_reference = try host.node.enrollForeign(
        foreign.peer_handle,
        .{ .far = model.FarRef.object(8) },
    );
    const pending = source.pendingOperations();
    const vows = host.vows.count();
    const routes = host.node.foreign_imports.count();
    try std.testing.expectError(
        core.HostError.ForeignArgument,
        host.routeSend(
            source,
            actor.nearRef(),
            &.{.{ .reference = foreign_reference }},
        ),
    );
    try std.testing.expectEqual(pending, source.pendingOperations());
    try std.testing.expectEqual(vows, host.vows.count());
    try std.testing.expectEqual(routes, host.node.foreign_imports.count());
    try std.testing.expect(source.served.port.peer.sessionIsOpen());
    try std.testing.expect(foreign.served.port.peer.sessionIsOpen());

    try source.served.port.peer.importObject(9);
    const accepted = try host.routeSend(
        source,
        actor.nearRef(),
        &.{.{ .reference = .{ .far = model.FarRef.object(9) } }},
    );
    try std.testing.expectEqual(source, accepted.session);
}
