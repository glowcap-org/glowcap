//! Who authored an over-deep value decides the error. A partner's tree past
//! `model.max_value_depth` is `NestingTooDeep`: the session aborts with
//! `resource_exhausted` and the partner is told. A local author's tree is
//! `ValueTooDeep`: the call is refused before any effect, no abort is
//! recorded, and the session keeps serving. A failure means one of the two
//! entries classified depth by the other's author.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../support/depth_shapes.zig");

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const abort_projection = engine.abort_projection;

const allocator = std.testing.allocator;

/// An `op:deliver` to live export 7 whose one argument nests `levels` lists
/// around a string leaf, so the leaf sits at depth `levels`, in its envelope.
fn deliverNested(levels: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "<10'op:deliver<11'desc:export7+>[");
    try body.appendNTimes(allocator, '[', levels);
    try body.appendSlice(allocator, "5:hello");
    try body.appendNTimes(allocator, ']', levels);
    try body.appendSlice(allocator, "]ff>");
    try bytes.print(allocator, "{d}:", .{body.items.len});
    try bytes.appendSlice(allocator, body.items);
    return bytes.toOwnedSlice(allocator);
}

test "a partner's over-deep deliver is NestingTooDeep and aborts resource_exhausted" {
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const admitted = try deliverNested(model.max_value_depth);
    defer allocator.free(admitted);
    try std.testing.expectEqual(net.RecvStream{ .consumed = admitted.len }, try net.recvOuterPrefix(&peer, admitted));
    try std.testing.expect(peer.lastAbort() == null);

    const over = try deliverNested(model.max_value_depth + 1);
    defer allocator.free(over);
    try std.testing.expectError(error.NestingTooDeep, net.recvOuterPrefix(&peer, over));
    const abort = peer.lastAbort() orelse return error.NoAbortRecorded;
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.kind);
    try std.testing.expectEqualStrings("NestingTooDeep", abort.error_name);
}

test "a local author's over-deep send is ValueTooDeep and leaves the session open" {
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const over = try shapes.ownedArgs(arena.allocator(), model.max_value_depth + 1, .leaf);
    try std.testing.expectError(error.ValueTooDeep, peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(9) },
        .args = over,
    } }));
    try std.testing.expect(peer.lastAbort() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    // The same peer still carries a call at the ceiling.
    const fits = try shapes.ownedArgs(arena.allocator(), model.max_value_depth, .leaf);
    try peer.sendBorrowed(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(9) }, .args = fits } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound() orelse return error.NoFrameQueued;
    frame.deinit();
}

test "the classifier names both depth errors by author" {
    const partner = abort_projection.classify(error.NestingTooDeep);
    try std.testing.expectEqual(abort_projection.Domain.session, partner.domain);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, partner.abort.?.kind);

    const local = abort_projection.classify(error.ValueTooDeep);
    try std.testing.expectEqual(abort_projection.Domain.session, local.domain);
    try std.testing.expect(local.abort == null);
}
