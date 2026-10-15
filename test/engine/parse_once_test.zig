//! An inbound message is parsed once. A transport's borrowed buffer is copied
//! behind the frame head the engine retains and parsed there, so the surfaced
//! event reads its own bytes and never the buffer the transport has since
//! reused. The argument list is parsed into that head's room (ADR-0222), so
//! the application walks views and the wire is read once.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;

const deliver_to_export7 = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";
/// The first argument is a list, which stays wire-backed inside the view
/// and borrows the frame through it.
const deliver_nested = "<10'op:deliver<11'desc:export7+>[5:hello[3:abc]]ff>";
/// One more argument than the head holds views for, so the list stays
/// wire-backed.
const deliver_five = "<10'op:deliver<11'desc:export7+>[5:hello1+2+3+4+]ff>";

fn firstArgumentBytes(event: *const engine.Event) ![]const u8 {
    const body = event.view();
    var it = body.deliver.args.iterator();
    const first = (try it.next()) orelse return error.TestUnexpectedResult;
    return switch (first) {
        .bytes => |bytes| bytes,
        else => error.TestUnexpectedResult,
    };
}

fn expectBorrowsFrame(event: *const engine.Event, bytes: []const u8) !void {
    const frame = event.bytes();
    const start = @intFromPtr(bytes.ptr);
    try std.testing.expect(start >= @intFromPtr(frame.ptr));
    try std.testing.expect(start + bytes.len <= @intFromPtr(frame.ptr) + frame.len);
    try std.testing.expectEqualStrings("hello", bytes);
}

/// The argument views live in the retained frame's head, which the stream
/// entry sized its own room by, so a list that fit there is view-backed.
fn expectViewsInHead(event: *const engine.Event) !void {
    const views = event.view().deliver.args.backingViews() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), views.len);
}

/// Hand `wire` to the peer as one packet and reuse the packet's storage
/// before the application drains the event, as a transport does.
fn feedPacket(peer: *engine.Peer, comptime wire: []const u8) !void {
    var packet: [wire.len]u8 = undefined;
    @memcpy(&packet, wire);
    try peer.recvPacket(&packet);
    @memset(&packet, 'x');
}

test "parse once: a packet frame's event borrows the retained frame, not the packet" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try feedPacket(&peer, deliver_to_export7);

    var event = peer.pollEvent() orelse return error.TestUnexpectedResult;
    defer event.deinit();
    try expectBorrowsFrame(&event, try firstArgumentBytes(&event));
    try expectViewsInHead(&event);
}

test "parse once: a list inside a head view borrows the retained frame" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try feedPacket(&peer, deliver_nested);

    var event = peer.pollEvent() orelse return error.TestUnexpectedResult;
    defer event.deinit();
    const views = event.view().deliver.args.backingViews() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try expectBorrowsFrame(&event, views[0].bytes);
    var inner = views[1].list.iterator();
    const first = (try inner.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abc", first.bytes);
    try std.testing.expect((try inner.next()) == null);
}

test "parse once: a list denser than the head's room stays wire-backed and reads the same" {
    // One-byte booleans outrun one view per `head_view_bytes`, so the room
    // runs out mid-list and the list falls back to the bytes.
    const booleans: [64]u8 = @splat('t');
    const dense = "<10'op:deliver<11'desc:export7+>[" ++ booleans ++ "]11+f>";
    try std.testing.expect(engine.events.headViewsFor(dense.len) < 64);
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try feedPacket(&peer, dense);

    var event = peer.pollEvent() orelse return error.TestUnexpectedResult;
    defer event.deinit();
    try std.testing.expect(event.view().deliver.args.backingViews() == null);
    try std.testing.expectEqual(@as(usize, 64), try event.view().deliver.args.len());
    try std.testing.expect((try event.view().deliver.args.at(63)).boolean);
}

test "parse once: a small frame keeps the floor of views, so five arguments stay wire-backed" {
    try std.testing.expect(deliver_five.len <= engine.events.small_frame_bytes);
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try feedPacket(&peer, deliver_five);

    var event = peer.pollEvent() orelse return error.TestUnexpectedResult;
    defer event.deinit();
    try std.testing.expect(event.view().deliver.args.backingViews() == null);
    try std.testing.expectEqual(@as(usize, 5), try event.view().deliver.args.len());
    try expectBorrowsFrame(&event, try firstArgumentBytes(&event));
}

test "parse once: a frame past the small class earns room for its whole tree" {
    const padding: [200]u8 = @splat('a');
    const wide = "<10'op:deliver<11'desc:export7+>[5:hello200:" ++ padding ++ "2+3+4+]ff>";
    try std.testing.expect(wide.len > engine.events.small_frame_bytes);
    try std.testing.expectEqual(wide.len / engine.events.head_view_bytes, engine.events.headViewsFor(wide.len));
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try feedPacket(&peer, wide);

    var event = peer.pollEvent() orelse return error.TestUnexpectedResult;
    defer event.deinit();
    try std.testing.expect(event.view().deliver.args.backingViews() != null);
    try std.testing.expectEqual(@as(usize, 5), try event.view().deliver.args.len());
    try expectBorrowsFrame(&event, try firstArgumentBytes(&event));
}

test "parse once: the engine's own frame lends its head for the argument views, an external frame lends nothing" {
    const allocator = std.testing.allocator;
    var headed = try engine.ownedFrameFromView(allocator, .{ .bytes = deliver_to_export7, .shape = .byte });
    defer headed.deinit();
    const lent = engine.events.Head.slabOf(&headed);
    try std.testing.expectEqual(engine.events.headViewsFor(deliver_to_export7.len), lent.bytes.len / @sizeOf(model.view.Argument));
    try std.testing.expectEqual(@as(usize, engine.events.head_argument_views), lent.bytes.len / @sizeOf(model.view.Argument));
    try std.testing.expectEqual(@as(usize, 0), lent.used);

    const Release = struct {
        fn release(_: *anyopaque) void {}
    };
    var storage = deliver_to_export7.*;
    var marker: u8 = 0;
    var external = try glowcap.foundation.Frame.initExternal(storage[0..], .byte, &marker, Release.release);
    defer external.deinit();
    const none = engine.events.Head.slabOf(&external);
    try std.testing.expectEqual(@as(usize, 0), none.bytes.len);
}
