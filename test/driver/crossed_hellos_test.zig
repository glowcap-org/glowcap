//! Crossed-hellos collision tiebreak (ADR-0012): when two peers dial each other
//! at once, each ends up with both an outbound and an inbound session to the same
//! partner, and the registry must steer both sides onto the *same* surviving
//! session with no coordination beyond a local comparison. The rule is the byte
//! order of the two Public Identifiers: the side whose identifier is not lower
//! aborts its inbound. The strictly lower-keyed side aborts its outbound. These
//! scenarios run the registry's verdict from both seats. The condemnation the
//! verdict drives (the losing connection's typed abort) is pinned by the core
//! host scenarios and the wire-level three-party test.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const CrossedHellos = glowcap.driver.core.CrossedHellos;
const DialTarget = glowcap.driver.core.DialTarget;

fn target(transport: []const u8, designator: []const u8) DialTarget {
    return .{ .transport = transport, .designator = designator };
}

fn pid(first: u8) foundation.PeerId {
    var bytes: [32]u8 = @splat(0);
    bytes[0] = first;
    return foundation.PeerId.fromBytes(bytes);
}

test "crossed hellos: the higher-keyed seat aborts its inbound, keeps its outbound" {
    const allocator = std.testing.allocator;
    const designator = "ocapn://partner.example";

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    // Our pid (9) is higher than the inbound partner's (1).
    try registry.registerOutbound(allocator, target("tcp", designator), pid(9));

    const verdict = registry.checkInbound(target("tcp", designator), pid(1)) orelse
        return error.ExpectedCollision;
    try std.testing.expect(verdict.abort_inbound);
}

test "crossed hellos: the lower-keyed seat keeps its inbound, aborts its outbound" {
    const allocator = std.testing.allocator;
    const designator = "ocapn://partner.example";

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    // Our pid (1) is lower than the inbound partner's (9): the verdict keeps
    // the inbound, and the host condemns its own outbound dial instead.
    try registry.registerOutbound(allocator, target("tcp", designator), pid(1));

    const verdict = registry.checkInbound(target("tcp", designator), pid(9)) orelse
        return error.ExpectedCollision;
    try std.testing.expect(!verdict.abort_inbound);
}

test "crossed hellos: equal identifiers abort inbound (no live session opens to self)" {
    const allocator = std.testing.allocator;
    const designator = "ocapn://partner.example";

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    try registry.registerOutbound(allocator, target("tcp", designator), pid(5));

    const verdict = registry.checkInbound(target("tcp", designator), pid(5)) orelse
        return error.ExpectedCollision;
    try std.testing.expect(verdict.abort_inbound);
}

test "crossed hellos: an inbound from an un-dialed partner is no collision" {
    const allocator = std.testing.allocator;

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    try registry.registerOutbound(allocator, target("tcp", "ocapn://peer-a.example"), pid(5));

    // No outbound to peer-b is in flight, so the inbound crosses nothing.
    try std.testing.expectEqual(
        @as(?CrossedHellos.Verdict, null),
        registry.checkInbound(target("tcp", "ocapn://peer-b.example"), pid(1)),
    );
}

test "crossed hellos: unregister drops the tracked outbound" {
    const allocator = std.testing.allocator;
    const designator = "ocapn://partner.example";

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    try registry.registerOutbound(allocator, target("tcp", designator), pid(2));
    registry.unregister(allocator, target("tcp", designator));

    // Once the outbound is unregistered the inbound finds nothing to cross with.
    try std.testing.expectEqual(
        @as(?CrossedHellos.Verdict, null),
        registry.checkInbound(target("tcp", designator), pid(1)),
    );
}

test "crossed hellos: unregister removes exactly one row, not every dial to the partner" {
    const allocator = std.testing.allocator;
    const designator = "ocapn://partner.example";

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    // Two concurrent dials to the same partner: tearing one down must leave
    // the sibling dial's row live for a crossed inbound to find.
    try registry.registerOutbound(allocator, target("tcp", designator), pid(2));
    try registry.registerOutbound(allocator, target("tcp", designator), pid(2));
    registry.unregister(allocator, target("tcp", designator));

    try std.testing.expect(registry.checkInbound(target("tcp", designator), pid(9)) != null);
}

test "crossed hellos: equal designators on different transports do not collide" {
    const allocator = std.testing.allocator;
    const designator = "same-target";

    var registry = CrossedHellos{};
    defer registry.deinit(allocator);

    try registry.registerOutbound(allocator, target("iroh", designator), pid(9));
    try std.testing.expectEqual(
        @as(?CrossedHellos.Verdict, null),
        registry.checkInbound(target("webrtc", designator), pid(1)),
    );
    try std.testing.expect(registry.checkInbound(target("iroh", designator), pid(1)) != null);
}
