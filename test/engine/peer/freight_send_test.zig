//! A deliver whose arguments the caller lends as views, freight (ADR-0246),
//! leaves as its frame at admission with the same bytes an owned tree
//! encodes to, and a refused freight admission commits nothing: a tree that
//! names a reference, one past the outbound budget, and an allocation that
//! fails mid-admission all leave the session as it was.

const std = @import("std");
const glowcap = @import("glowcap");
const codec = glowcap.ocapn.codec;

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const view = model.view;
const peer_fixture = @import("../../support/peer_fixture.zig");

const profiles = [_]model.CaptpVersion{ .v1_0, .next };
const target: model.Reference = .{ .far = model.FarRef.object(7) };

fn drainOne(peer: *engine.Peer, profile: model.CaptpVersion) ![]u8 {
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound() orelse return error.MissingDeliver;
    defer frame.deinit();
    const bytes = try std.testing.allocator.dupe(u8, frame.bytes());
    errdefer std.testing.allocator.free(bytes);
    const body = try codec.syrup.decodeBodyForProfile(profile, frame.view());
    try std.testing.expect(body.deliver.resolve_me_desc != null);
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.pending_send.isEmpty());
    return bytes;
}

test "freight is queued at admission as the bytes an owned tree encodes to" {
    for (profiles) |profile| {
        var peer = peer_fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
        defer peer.deinit();
        try peer.session_state.registerImport(.from(7));

        var payload: [5]u8 = "hello".*;
        var samples = [_]view.Argument{ .{ .integer = 1 }, .{ .integer = -2 } };
        const views = [_]view.Argument{ .{ .bytes = &payload }, .{ .list = .fromViews(&samples) } };
        try peer.sendFreight(target, .fromViews(&views), .from(42));
        try std.testing.expect(peer.pending_send.peek().?.item == .encoded);
        // The caller's storage is its own again: mutating it changes nothing.
        payload = "bye!!".*;
        const from_views = try drainOne(&peer, profile);
        defer std.testing.allocator.free(from_views);
        try std.testing.expect(std.mem.indexOf(u8, from_views, "hello") != null);

        // A second peer in the same state sends the owned tree, so the two
        // frames mint the same answer and resolver positions.
        var owned_peer = peer_fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
        defer owned_peer.deinit();
        try owned_peer.session_state.registerImport(.from(7));
        payload = "hello".*;
        const owned_samples = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = -2 } };
        try owned_peer.sendBorrowed(.{ .deliver = .{
            .target = target,
            .args = &.{ .{ .bytes = &payload }, .{ .list = &owned_samples } },
            .answer = .from(42),
        } });
        const from_owned = try drainOne(&owned_peer, profile);
        defer std.testing.allocator.free(from_owned);
        try std.testing.expectEqualSlices(u8, from_owned, from_views);
    }
}

test "freight that names a reference is refused with nothing committed" {
    var peer = peer_fixture.openPeer(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));
    const near = model.ExportPosition.from(try peer.exportNextObject());
    const before_count = peer.session_state.exportRefcount(near);
    const inner = [_]view.Argument{.{ .reference = .{ .near = .{ .export_position = near } } }};
    const views = [_]view.Argument{ .{ .bytes = "freight" }, .{ .list = .fromViews(&inner) } };
    try std.testing.expectError(error.MalformedMessage, peer.sendFreight(target, .fromViews(&views), .from(42)));
    try std.testing.expect(peer.pending_send.isEmpty());
    try std.testing.expectEqual(before_count, peer.session_state.exportRefcount(near));
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "freight past the outbound budget is refused before its frame exists" {
    var peer = peer_fixture.openPeer(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));
    peer.outbound_budget = 64;
    const big = try std.testing.allocator.alloc(u8, peer.outbound_budget + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    peer.allocator = failing.allocator();
    defer peer.allocator = std.testing.allocator;
    failing.fail_index = failing.alloc_index;
    const views = [_]view.Argument{.{ .bytes = big }};
    try std.testing.expectError(error.OutboundBackpressure, peer.sendFreight(target, .fromViews(&views), .from(42)));
    try std.testing.expect(peer.pending_send.isEmpty());
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
}

test "a refused freight admission commits nothing and the same send retries" {
    for (profiles) |profile| {
        var offset: usize = 0;
        var saw_success = false;
        while (!saw_success) : (offset += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var peer = peer_fixture.openPeerWith(failing.allocator(), .{ .captp_version = profile });
            defer peer.deinit();
            defer failing.fail_index = std.math.maxInt(usize);
            try peer.session_state.registerImport(.from(7));
            const twice = [_]view.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
            const views = [_]view.Argument{ .{ .bytes = "freight" }, .{ .set = .fromViews(&twice) } };

            failing.fail_index = failing.alloc_index + offset;
            const attempt = peer.sendFreight(target, .fromViews(&views), .from(42));
            failing.fail_index = std.math.maxInt(usize);
            if (attempt) |_| {
                saw_success = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(peer.pending_send.isEmpty());
                try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
                try std.testing.expectEqual(
                    @as(?model.ExportPosition, null),
                    peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = .from(42) }),
                );
                try peer.sendFreight(target, .fromViews(&views), .from(42));
            }
            const bytes = try drainOne(&peer, profile);
            std.testing.allocator.free(bytes);
        }
        try std.testing.expect(offset > 1);
    }
}
