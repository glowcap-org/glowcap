//! Engine peer fixtures for single-peer projection and resolve-window tests.
//! Consumers: `test/engine/projection_test.zig`, `test/engine/resolve_window_test.zig`.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const session = pancake.ocapn.session;

pub const OpenOptions = struct {
    wire_profile: model.WireProfile = model.WireProfile.pre_spec,
    features: model.FeatureSet = model.FeatureSet.full(),
};

pub fn openPeerWith(allocator: std.mem.Allocator, opts: OpenOptions) engine.Peer {
    return engine.Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
        .wire_profile = opts.wire_profile,
        .features = opts.features,
    }));
}

pub fn openPeer(allocator: std.mem.Allocator) engine.Peer {
    return openPeerWith(allocator, .{});
}

/// Receive a deliver creating inbound answer `answer` so a projection can
/// anchor on it. Export 7 is the registered target; the surfaced event is
/// drained so the queue stays empty for the assertions.
pub fn receiveCallCreatingAnswer(peer: *engine.Peer, comptime frame: []const u8) !void {
    try peer.recvBorrowed(.{ .bytes = frame, .shape = .byte });
    var event = peer.pollEvent().?;
    event.deinit();
}

/// Step until idle (a projected resolve queued during one step encodes on a
/// later one) and drain every encoded outbound frame into one buffer for byte
/// assertions.
pub fn drainOutbound(peer: *engine.Peer, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while ((try peer.step()) == .progress) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try out.appendSlice(allocator, frame.bytes());
    }
    return out.toOwnedSlice(allocator);
}
