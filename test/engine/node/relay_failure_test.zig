//! Relayed settlement under failure: a gift-id failure after the home fire
//! spends no allocation, and a recipient materialization failure under
//! allocation pressure breaks the projection from its admission escrow.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;

const Node = engine.Node;

const harness = @import("harness.zig");
const projection_support = @import("../../support/projection.zig");
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

test "relayed gift-id failure spends no allocation after the home fire" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.seed_bytes]u8, @splat(0x76)));
    defer node.deinit();
    defer failing.fail_index = std.math.maxInt(usize);

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(recipient).?,
        @as([crypto.seed_bytes]u8, @splat(0x75)),
    );
    defer recipient_counterpart.deinit();
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.seed_bytes]u8, @splat(0x77)),
    );
    defer home_counterpart.deinit();

    try node.peer(home).?.session_state.registerImport(.from(4));
    const route = try node.enrollForeign(home, model.FarRef.promise(4));
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient).?.session_state.exports.retain(.from(import_pos));
    try std.testing.expectEqual(home, node.nextAction().?.flush);
    try node.peer(recipient).?.session_state.retainImportForSession(.from(12));
    const recipient_session = &node.peer(recipient).?.session_state;
    try recipient_session.installListenerNamed(recipient_session.answerForLocalPromiseExport(.from(import_pos)).?, .{
        .listener = .{ .import_position = .from(12) },
        .mode = .settling_only,
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    try node.peer(home).?.session_state.registerImport(.from(9));
    const gifted = try node.enrollForeign(home, model.FarRef.object(9));
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = gifted },
    }));
    const ask = node.nextAction().?;
    try std.testing.expect(ask == .need_gift_id);

    // The source fire and its only retry opportunity are gone. Admission
    // reserved the terminal resolution, so reporting entropy failure must
    // settle even when the allocator refuses every request from here onward.
    failing.fail_index = failing.alloc_index;
    try node.giftIdFailed(ask.need_gift_id.ticket);
    const settled = projection_support.resolution(&node.peer(recipient).?.session_state, .from(import_pos)).?;
    try std.testing.expect(settled.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", settled.@"break".message);

    // The admission-time scheduler reservation becomes a recipient flush even
    // though no carrier could be allocated yet. Once pressure clears, `step` status-allow: pending state or quoted runtime label
    // retries the stored settlement and emits the listener fire exactly once.
    try std.testing.expectEqual(recipient, node.nextAction().?.flush);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(recipient).?.step());
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(recipient).?.step());
    var fire = node.peer(recipient).?.takeOutbound().?;
    defer fire.deinit();
    const fire_body = try glowcap.ocapn.codec.syrup.decodeBody(fire.view());
    try std.testing.expect(fire_body == .deliver);
    var release = node.peer(recipient).?.takeOutbound().?;
    defer release.deinit();
    const release_body = try glowcap.ocapn.codec.syrup.decodeBody(release.view());
    try std.testing.expect(release_body == .gc_export);
    try std.testing.expect(node.peer(recipient).?.takeOutbound() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try node.peer(recipient).?.step());
}

test "a projected relayed value breaks from admission escrow under allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.seed_bytes]u8, @splat(0x78)));
    defer node.deinit();
    defer failing.fail_index = std.math.maxInt(usize);

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.seed_bytes]u8, @splat(0x79)),
    );
    defer home_counterpart.deinit();

    try node.peer(home).?.session_state.registerImport(.from(4));
    const route = try node.enrollForeign(home, model.FarRef.promise(4));
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient).?.session_state.exports.retain(.from(import_pos));
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    // The already-consumed source fire cannot be retried when recipient
    // materialization fails. Its admission escrow must still settle broken
    // without a best-effort allocation.
    try node.peer(home).?.session_state.registerImport(.from(10));
    const chained = try node.enrollForeign(home, model.FarRef.promise(10));
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = chained },
    }));
    const settled = projection_support.resolution(&node.peer(recipient).?.session_state, .from(import_pos)).?;
    try std.testing.expect(settled.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", settled.@"break".message);
}
