//! A pipelined call whose answer settles to a value this session holds but
//! cannot deliver to (a sturdyref) breaks the call's own answer, so the
//! caller's promise settles instead of hanging.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const peer_fixture = @import("../../support/peer_fixture.zig");

test "a pipelined call onto an answer that resolved to a sturdyref breaks with a named reason" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    try peer.session_state.installInboundAnswer(.from(42));
    const sturdy = model.SturdyRef{
        .peer = .{ .transport = "onion", .designator = "abc", .hints = model.Hints.emptyFalse() },
        .swissnum = "swiss",
    };
    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .sturdy = &sturdy } } },
    } });
    {
        const sent = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(sent);
    }

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:answer42+>[4\"ping]43+<18'desc:import-object0+>1+>",
        .shape = .byte,
    });
    try std.testing.expect(peer.pollEvent() == null);
    const sent = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(sent);
    try std.testing.expectEqual(session.AnswerStatus.broken, peer.session_state.inboundAnswer(.from(43)).?.status);
    try std.testing.expectEqualStrings(
        engine.pipeline.undeliverable_target_message,
        peer.session_state.peekResolution(.from(43)).?.@"break".message,
    );
    try std.testing.expect(peer.sessionIsOpen());
}
