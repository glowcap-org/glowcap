//! Engine peer fixtures for single-peer projection and resolve-window tests.
//! Consumers: `test/engine/projection_test.zig`, `test/engine/resolve_window_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const codec = glowcap.ocapn.codec;
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

pub const OpenOptions = struct {
    captp_version: model.CaptpVersion = model.CaptpVersion.next,
    features: model.FeatureSet = model.FeatureSet.full(),
};

pub fn openPeerWith(allocator: std.mem.Allocator, opts: OpenOptions) engine.Peer {
    return engine.Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
        .captp_version = opts.captp_version,
        .features = opts.features,
    }));
}

pub fn openPeer(allocator: std.mem.Allocator) engine.Peer {
    return openPeerWith(allocator, .{});
}

/// Receive a deliver creating inbound answer `answer` so a projection can
/// anchor on it. Export 7 is the registered target. The surfaced event is
/// drained so the queue stays empty for the assertions.
pub fn receiveCallCreatingAnswer(peer: *engine.Peer, comptime frame: []const u8) !void {
    try receiveAnsweredOperation(peer, frame);
}

pub fn receiveAnsweredOperation(peer: *engine.Peer, frame: []const u8) !void {
    const body = try codec.syrup.decodeBodyForProfile(peer.session_state.captp_version, .{ .bytes = frame, .shape = .byte });
    const answer = switch (body) {
        .deliver => |deliver| deliver.answer orelse return error.TestUnexpectedResult,
        .get => |get| get.answer,
        .index => |index| index.answer,
        .untag => |untag| untag.answer,
        else => return error.TestUnexpectedResult,
    };

    try peer.recvBorrowed(.{ .bytes = frame, .shape = .byte });
    var event = peer.pollEvent().?;
    event.deinit();

    if (peer.session_state.captp_version != .next or body != .deliver or body.deliver.resolve_me_desc == null)
        try receiveListenerForAnswer(peer, answer);
}

pub fn receiveListenerForAnswer(peer: *engine.Peer, answer: model.AnswerPosition) !void {
    const listener_position = listenerPosition(answer);
    var listener = try codec.syrup.encodeMessageForProfile(peer.allocator, peer.session_state.captp_version, .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = answer } },
        .listener = .{ .near = model.NearRef.object(listener_position) },
        .mode = .shortening_or_settling,
    } });
    defer listener.deinit();
    try peer.recvBorrowed(listener.view());
    var listen_event = peer.pollEvent().?;
    listen_event.deinit();
}

/// Emulate the partner invoking the mandatory listener export bound to an
/// outbound answer. The callback is consumed as a semantic resolve event.
pub fn receiveResolverCallback(peer: *engine.Peer, answer: model.AnswerPosition, resolution: model.Resolution) !void {
    const target = peer.session_state.resolverExportForAnswer(answer) orelse return error.TestUnexpectedResult;
    var args: [2]model.Argument = switch (resolution) {
        .fulfill => |value| .{ .{ .symbol = "fulfill" }, value },
        .@"break" => |reason| .{ .{ .symbol = "break" }, .{ .symbol = reason.message } },
    };
    var frame = try codec.syrup.encodeMessageForProfile(peer.allocator, peer.session_state.captp_version, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(target.int()) },
        .args = &args,
    } });
    defer frame.deinit();
    try peer.recvBorrowed(frame.view());
    var event = peer.pollEvent().?;
    event.deinit();
}

pub fn listenerPosition(answer: model.AnswerPosition) u64 {
    return 0x1000_0000 + answer.int();
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
