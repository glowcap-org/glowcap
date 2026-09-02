//! Logical-close and aggregate-teardown ownership for committed promise proxies.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const Node = engine.Node;

const openKeyedSessionWithCounterpart = @import("../harness.zig").openKeyedSessionWithCounterpart;

test "closing a committed proxy home breaks its recipient at logical close" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x71)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x72)),
    );
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const projected = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const recipient_import = projected.near.export_position.int();

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    var frame = node.peer(home).?.takeOutbound().?;
    defer frame.deinit();
    const body = try codec.syrup.decodeBody(frame.view());
    const listener = body.listen.listener.far.import_position.int();
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    node.peer(home).?.closeSession();

    const resolution = node.peer(recipient).?.session_state.importedPromiseResolution(.from(recipient_import)).?;
    try std.testing.expect(resolution.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", resolution.@"break".message);
    try std.testing.expect(!node.isProxyHomeListener(home, listener));
    try std.testing.expectEqual(recipient, node.nextAction().?.flush);
    try std.testing.expect(node.nextAction() == null);

    // Close is idempotent and cannot spend the terminal escrow twice.
    node.peer(home).?.closeSession();
    try std.testing.expect(node.nextAction() == null);
}

test "closing a committed proxy recipient retires its escrow and home listener" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x73)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x74)),
    );
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    _ = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    var frame = node.peer(home).?.takeOutbound().?;
    defer frame.deinit();
    const body = try codec.syrup.decodeBody(frame.view());
    const listener = body.listen.listener.far.import_position.int();
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    node.peer(recipient).?.closeSession();

    try std.testing.expect(!node.isProxyHomeListener(home, listener));
    try std.testing.expect(node.nextAction() == null);
    const payload = try allocator.dupe(u8, "late");
    defer allocator.free(payload);
    try std.testing.expect(!node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .bytes = payload },
    }));
}

test "node teardown breaks committed proxies retained by borrowed peers" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x75)));

    const home = try node.registerPeer(.{});
    var borrowed = engine.Peer.initNegotiating(allocator);
    defer borrowed.deinit();
    const recipient = try node.registerPeerOver(&borrowed);
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x76)),
    );
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const projected = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const recipient_import = projected.near.export_position.int();

    node.deinit();

    try std.testing.expect(borrowed.node_services == null);
    const resolution = borrowed.session_state.importedPromiseResolution(.from(recipient_import)).?;
    try std.testing.expect(resolution.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", resolution.@"break".message);
}

test "node teardown breaks entropy-delayed proxy work retained by a borrowed peer" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x77)));

    const home = try node.registerPeer(.{});
    var borrowed = engine.Peer.initNegotiating(allocator);
    defer borrowed.deinit();
    const recipient = try node.registerPeerOver(&borrowed);
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x78)),
    );
    defer home_counterpart.deinit();

    try node.peer(home).?.session_state.registerImport(.from(4));
    try node.peer(home).?.session_state.registerImport(.from(5));
    const promise = try node.enrollForeign(home, .{ .far = model.FarRef.promise(4) });
    const gifted = try node.enrollForeign(home, .{ .far = model.FarRef.object(5) });
    const projected = (try node.proxyForeignPromiseFulfill(recipient, promise.routed.id)).?;
    const recipient_import = projected.near.export_position.int();
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    var frame = node.peer(home).?.takeOutbound().?;
    defer frame.deinit();
    const body = try codec.syrup.decodeBody(frame.view());
    const listener = body.listen.listener.far.import_position.int();
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = gifted },
    }));
    try std.testing.expect(node.nextAction().? == .need_gift_id);
    try std.testing.expect(borrowed.session_state.importedPromiseResolution(.from(recipient_import)) == null);

    node.deinit();

    const resolution = borrowed.session_state.importedPromiseResolution(.from(recipient_import)).?;
    try std.testing.expect(resolution.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", resolution.@"break".message);
}
