//! Shared mechanics for canonical multi-peer oracle scenarios.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const appendTraceLine = @import("../trace.zig").appendLine;

/// A negotiating peer fixed to the interop-floor profile with real handshake
/// verification enabled.
pub fn keyedNegotiatingPeer(allocator: std.mem.Allocator, codec_id: model.CodecId) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .v1_0,
        .codec = codec_id,
        .features = model.FeatureSet.full(),
    });
}

/// Drive one signed keyed hello exchange to an open session.
pub fn openKeyedSession(
    p1: *engine.Peer,
    p1_secret: foundation.crypto.SecretKey,
    p1_designator: []const u8,
    p2: *engine.Peer,
    p2_secret: foundation.crypto.SecretKey,
    p2_designator: []const u8,
) !void {
    try p1.sendKeyedStartSession(
        .{ .transport = "tcp", .designator = p1_designator, .hints = model.Hints.emptyFalse() },
        p1_secret,
    );
    try p2.sendKeyedStartSession(
        .{ .transport = "tcp", .designator = p2_designator, .hints = model.Hints.emptyFalse() },
        p2_secret,
    );
    if (try engine.pairing.shuttleUntilQuiescent(p1, p2) != .quiescent)
        return error.HandshakeDidNotQuiesce;
    drainEvents(p1);
    drainEvents(p2);
}

fn drainEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
}

/// Move every queued outbound frame, then trace each surfaced event.
pub fn shuttleAndTraceEvents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sender: *engine.Peer,
    receiver: *engine.Peer,
    receiver_name: []const u8,
) !void {
    try shuttleFrames(sender, receiver);
    try traceReceiverEvents(allocator, out, receiver, receiver_name);
}

/// Move queued frames until the sender produces no further work.
pub fn shuttleFrames(sender: *engine.Peer, receiver: *engine.Peer) !void {
    while (true) {
        const result = try sender.step();
        var moved = false;
        while (sender.takeOutbound()) |frame| {
            try receiver.feedOwned(frame);
            _ = try receiver.step();
            moved = true;
        }
        if (result == .idle and !moved) return;
    }
}

fn traceReceiverEvents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    receiver: *engine.Peer,
    receiver_name: []const u8,
) !void {
    while (receiver.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.kind() == .resolve) {
            const view = event.view();
            switch (view.resolve.resolution) {
                .fulfill => |payload| switch (payload) {
                    .string => |text| try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:fulfill={s}\n", .{ receiver_name, view.resolve.answer, text }),
                    .integer => |value| try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:fulfill={d}\n", .{ receiver_name, view.resolve.answer, value }),
                    else => try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:fulfill={s}\n", .{ receiver_name, view.resolve.answer, @tagName(payload) }),
                },
                else => try appendTraceLine(allocator, out, "{s}=event:resolve:answer={d}:{s}\n", .{ receiver_name, view.resolve.answer, @tagName(view.resolve.resolution) }),
            }
        } else {
            try appendTraceLine(allocator, out, "{s}=event:{s}\n", .{ receiver_name, @tagName(event.kind()) });
        }
    }
}
