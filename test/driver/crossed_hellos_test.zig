//! Crossed-hellos collision tiebreak (ADR-0030): when two peers dial each other
//! at once, each ends up with both an outbound and an inbound session to the same
//! partner, and the registry must steer both sides onto the *same* surviving
//! session with no coordination beyond a local comparison. The rule is the byte
//! order of the two Public Identifiers: the side whose identifier is not lower
//! aborts its inbound; the strictly lower-keyed side aborts its outbound. Run from
//! both seats that converges on the higher-keyed peer's outbound session, the
//! load-bearing property this module exists to hold.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const crossed_hellos = pancake.driver.crossed_hellos;

fn pid(first: u8) foundation.PeerId {
    var bytes: [32]u8 = @splat(0);
    bytes[0] = first;
    return foundation.PeerId.fromBytes(bytes);
}

test "crossed hellos: the higher-keyed seat aborts its inbound, keeps its outbound" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const designator = "ocapn://partner.example";

    var registry = crossed_hellos.Registry{};
    defer registry.deinit(io, allocator);

    // Our pid (9) is higher than the inbound partner's (1).
    try registry.registerOutbound(io, allocator, designator, pid(9));

    const result = registry.checkInbound(io, designator, pid(1)) orelse
        return error.ExpectedCollision;
    try std.testing.expect(result.abort_inbound);
    // The higher seat keeps its outbound, so it must not also tear it down.
    try std.testing.expect(!registry.shouldAbortOutbound(io, designator));
}

test "crossed hellos: the lower-keyed seat keeps its inbound, aborts its outbound" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const designator = "ocapn://partner.example";

    var registry = crossed_hellos.Registry{};
    defer registry.deinit(io, allocator);

    // Our pid (1) is lower than the inbound partner's (9).
    try registry.registerOutbound(io, allocator, designator, pid(1));

    const result = registry.checkInbound(io, designator, pid(9)) orelse
        return error.ExpectedCollision;
    try std.testing.expect(!result.abort_inbound);
    // The lower seat tears down its outbound so the partner's survives.
    try std.testing.expect(registry.shouldAbortOutbound(io, designator));
}

test "crossed hellos: equal identifiers abort inbound (no live session opens to self)" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const designator = "ocapn://partner.example";

    var registry = crossed_hellos.Registry{};
    defer registry.deinit(io, allocator);

    try registry.registerOutbound(io, allocator, designator, pid(5));

    const result = registry.checkInbound(io, designator, pid(5)) orelse
        return error.ExpectedCollision;
    try std.testing.expect(result.abort_inbound);
    try std.testing.expect(!registry.shouldAbortOutbound(io, designator));
}

test "crossed hellos: an inbound from an un-dialed partner is no collision" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = crossed_hellos.Registry{};
    defer registry.deinit(io, allocator);

    try registry.registerOutbound(io, allocator, "ocapn://peer-a.example", pid(5));

    // No outbound to peer-b is in flight, so the inbound crosses nothing.
    try std.testing.expectEqual(
        @as(?crossed_hellos.Result, null),
        registry.checkInbound(io, "ocapn://peer-b.example", pid(1)),
    );
    try std.testing.expect(!registry.shouldAbortOutbound(io, "ocapn://peer-b.example"));
}

test "crossed hellos: unregister drops the tracked outbound" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const designator = "ocapn://partner.example";

    var registry = crossed_hellos.Registry{};
    defer registry.deinit(io, allocator);

    try registry.registerOutbound(io, allocator, designator, pid(2));
    registry.unregister(io, allocator, designator);

    // Once the outbound is unregistered the inbound finds nothing to cross with.
    try std.testing.expectEqual(
        @as(?crossed_hellos.Result, null),
        registry.checkInbound(io, designator, pid(1)),
    );
}
