const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const runtime = pancake.runtime;

fn peerId(seed: u8) foundation.PeerId {
    return foundation.PeerId.fromBytes([_]u8{seed} ** 32);
}

test "SessionRegistry admits distinct peers and refuses a duplicate" {
    const allocator = std.testing.allocator;
    var reg = runtime.SessionRegistry.empty;
    defer reg.deinit(allocator);

    try reg.register(allocator, peerId(1));
    try reg.register(allocator, peerId(2));
    try std.testing.expect(reg.contains(peerId(1)));
    try std.testing.expect(reg.contains(peerId(2)));
    try std.testing.expect(!reg.contains(peerId(3)));

    // A second session to an already-open peer is a loud refusal (ADR-0013 § 1).
    try std.testing.expectError(
        runtime.registry.Error.PeerAlreadyOpen,
        reg.register(allocator, peerId(1)),
    );
}

test "SessionRegistry unregister frees the slot for a fresh session" {
    const allocator = std.testing.allocator;
    var reg = runtime.SessionRegistry.empty;
    defer reg.deinit(allocator);

    try reg.register(allocator, peerId(1));
    try std.testing.expect(reg.unregister(peerId(1)));
    try std.testing.expect(!reg.contains(peerId(1)));

    // Unregistering an absent peer reports no removal.
    try std.testing.expect(!reg.unregister(peerId(1)));

    // The slot is free: a fresh session to the same peer now succeeds.
    try reg.register(allocator, peerId(1));
    try std.testing.expect(reg.contains(peerId(1)));
}
