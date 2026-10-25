//! Local projection custody while a Node payload waits for gift entropy.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const crypto = glowcap.foundation.crypto;
const Node = glowcap.ocapn.engine.Node;
const openKeyedSessionWithCounterpart = @import("harness.zig").openKeyedSessionWithCounterpart;

test "staged local promise survives backing settlement before gift entropy" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        inline for (.{ model.CaptpVersion.next, model.CaptpVersion.v1_0 }) |profile| {
            for ([_]bool{ false, true }) |abandon| try exercise(codec_id, profile, abandon);
        }
    }
}

fn exercise(codec_id: model.CodecId, profile: model.CaptpVersion, abandon: bool) !void {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.seed_bytes]u8, @splat(0x81)));
    defer node.deinit();
    const recipient_id = try node.registerPeer(.{});
    const home_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const home = node.peer(home_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, recipient, @as([crypto.seed_bytes]u8, @splat(0x82)));
    defer recipient_counterpart.deinit();
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, home, @as([crypto.seed_bytes]u8, @splat(0x83)));
    defer home_counterpart.deinit();
    recipient.session_state.codec = codec_id;
    recipient.session_state.captp_version = profile;
    try recipient.session_state.registerImport(.from(2));
    try home.session_state.registerImport(.from(4));
    const object = try node.enrollForeign(home_id, model.FarRef.object(4));
    const local = try recipient.session_state.allocateLocalPromiseProjection();
    // The settlement carrier precedes the staged barrier. Pumping can retire
    // it while the later mixed payload is still waiting for gift entropy.
    try recipient.sendAnswerResolutionCopying(local.answer_name, .{ .fulfill = .{ .bytes = "settled" } });
    try recipient.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{
            .{ .reference = object },
            .{ .reference = .{ .near = model.NearRef.promise(local.export_position.int()) } },
            .{ .list = &.{.{ .reference = .{ .near = model.NearRef.promise(local.export_position.int()) } }} },
        },
    } });
    const ticket = node.nextAction().?.need_gift_id.ticket;
    try recipient.stepToIdle();
    try std.testing.expect(recipient.session_state.hasExport(local.export_position));
    try std.testing.expectEqual(@as(u32, 2), recipient.session_state.exports.purpose(local.export_position).?.local_promise_answer.staging_owners);
    // Private staging custody cannot be spent by a peer's wire release.
    try std.testing.expectEqual(@as(u64, 0), recipient.session_state.exports.wireHeld(local.export_position));
    try std.testing.expectError(error.GcUnderflow, recipient.session_state.recordRecv(.{ .gc_export = .{
        .positions = &.{local.export_position.int()},
        .deltas = &.{1},
    } }));
    try std.testing.expectEqual(@as(u32, 2), recipient.session_state.exports.purpose(local.export_position).?.local_promise_answer.staging_owners);
    if (abandon) {
        try node.giftIdFailed(ticket);
        recipient.session_state.collectLocalPromiseProjectionsNow();
        try std.testing.expect(!recipient.session_state.hasExport(local.export_position));
        try std.testing.expect(recipient.session_state.inboundAnswerNamed(local.answer_name) == null);
        return;
    }
    const gift_id = @as([model.handoff_gift_id_bytes]u8, @splat(0x84));
    try node.provideGiftId(ticket, &gift_id);
    try recipient.stepToIdle();
    var frame = recipient.takeOutbound() orelse return error.MissingStagedDeliver;
    defer frame.deinit();
    const deliver = (try codec.dispatch.decodeBodyForProfile(recipient.session_state.codec, recipient.session_state.captp_version, frame.view())).deliver;
    const returned = (try deliver.args.at(1)).reference;
    try std.testing.expect(returned == .far);
    try std.testing.expectEqual(local.export_position.int(), returned.far.import_position.int());
    try std.testing.expectEqual(@as(u32, 0), recipient.session_state.exports.purpose(local.export_position).?.local_promise_answer.staging_owners);
    try recipient.session_state.recordRecv(.{ .gc_export = .{
        .positions = &.{local.export_position.int()},
        .deltas = &.{2},
    } });
    recipient.session_state.collectLocalPromiseProjectionsNow();
    try std.testing.expect(!recipient.session_state.hasExport(local.export_position));
    try std.testing.expect(recipient.session_state.inboundAnswerNamed(local.answer_name) == null);
}
