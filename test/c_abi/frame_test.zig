const std = @import("std");
const pancake = @import("pancake");

const c_abi = pancake.c_abi;

test "frame shape constants use canonical byte and word terms" {
    try std.testing.expectEqual(@as(u32, 0), c_abi.PANCAKE_FRAME_SHAPE_BYTE);
    try std.testing.expectEqual(@as(u32, 1), c_abi.PANCAKE_FRAME_SHAPE_WORD);
}

test "managed frame release is null safe and idempotent" {
    const Callback = struct {
        var calls: usize = 0;

        fn release(frame: *c_abi.PancakeManagedFrame) callconv(.c) void {
            calls += 1;
            frame.bytes = null;
            frame.len = 0;
            frame.shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE;
            frame.private_data = null;
        }
    };

    var bytes = [_]u8{ 9, 8, 7 };
    var managed = c_abi.PancakeManagedFrame{
        .bytes = bytes[0..].ptr,
        .len = bytes.len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
        .release = Callback.release,
        .private_data = null,
    };

    c_abi.pancake_managed_frame_release(&managed);
    c_abi.pancake_managed_frame_release(&managed);
    c_abi.pancake_managed_frame_release(null);

    try std.testing.expectEqual(@as(usize, 1), Callback.calls);
    try std.testing.expectEqual(@as(?[*]u8, null), managed.bytes);
    try std.testing.expectEqual(@as(usize, 0), managed.len);
    try std.testing.expectEqual(@as(?c_abi.ReleaseFn, null), managed.release);
}

test "C ABI peer handles borrowed abort frames" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new(&peer));
    defer c_abi.pancake_peer_release(peer);

    const frame = c_abi.PancakeFrame{
        .bytes = "<8'op:abort3\"bye>".ptr,
        .len = "<8'op:abort3\"bye>".len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
    };
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_feed_borrowed(peer, &frame));

    var event: c_abi.PancakeEvent = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    defer c_abi.pancake_event_release(&event);
    try std.testing.expectEqual(c_abi.PANCAKE_EVENT_ABORT, event.kind);
    try std.testing.expectEqualStrings("<8'op:abort3\"bye>", event.frame.bytes.?[0..event.frame.len]);
}

test "C ABI exposes non-abort events as managed event frames in the negotiated codec" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new(&peer));
    defer c_abi.pancake_peer_release(peer);

    const frame = c_abi.PancakeFrame{
        .bytes = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>".ptr,
        .len = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>".len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
    };
    const runtime_peer: *pancake.runtime.Peer = @ptrCast(@alignCast(peer.?));
    try runtime_peer.session_state.registerExport(7);
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_feed_borrowed(peer, &frame));

    var event: c_abi.PancakeEvent = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    defer c_abi.pancake_event_release(&event);

    try std.testing.expectEqual(c_abi.PANCAKE_EVENT_DELIVER, event.kind);
    try std.testing.expectEqualStrings(
        "<10'op:deliver<11'desc:export7+>[5:hello]11+f>",
        event.frame.bytes.?[0..event.frame.len],
    );
    try std.testing.expect(event.frame.release != null);
}

test "C ABI poll event hands back the originating frame pointer without re-encoding" {
    const Callback = struct {
        fn release(frame: *c_abi.PancakeManagedFrame) callconv(.c) void {
            frame.bytes = null;
            frame.len = 0;
            frame.release = null;
            frame.private_data = null;
        }
    };

    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new(&peer));
    defer c_abi.pancake_peer_release(peer);

    var bytes = [_]u8{ '<', '8', '\'', 'o', 'p', ':', 'a', 'b', 'o', 'r', 't', '3', '"', 'b', 'y', 'e', '>' };
    const source_ptr = @intFromPtr(bytes[0..].ptr);
    var managed = c_abi.PancakeManagedFrame{
        .bytes = bytes[0..].ptr,
        .len = bytes.len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
        .release = Callback.release,
        .private_data = null,
    };

    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_feed_owned(peer, &managed));
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_step(peer));

    var event: c_abi.PancakeEvent = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    defer c_abi.pancake_event_release(&event);
    try std.testing.expectEqual(source_ptr, @intFromPtr(event.frame.bytes.?));
}

test "C ABI peer step and take outbound are null safe when idle" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new(&peer));
    defer c_abi.pancake_peer_release(peer);

    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_step(peer));

    var outbound: c_abi.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_ERR_WOULD_BLOCK, c_abi.pancake_peer_take_outbound(peer, &outbound));
}

test "C ABI owned feed moves the frame end to end and releases it once at event release" {
    const Callback = struct {
        var calls: usize = 0;

        fn release(frame: *c_abi.PancakeManagedFrame) callconv(.c) void {
            calls += 1;
            frame.bytes = null;
            frame.len = 0;
            frame.release = null;
            frame.private_data = null;
        }
    };

    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new(&peer));
    defer c_abi.pancake_peer_release(peer);

    var bytes = [_]u8{ '<', '8', '\'', 'o', 'p', ':', 'a', 'b', 'o', 'r', 't', '3', '"', 'b', 'y', 'e', '>' };
    var managed = c_abi.PancakeManagedFrame{
        .bytes = bytes[0..].ptr,
        .len = bytes.len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
        .release = Callback.release,
        .private_data = null,
    };

    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_feed_owned(peer, &managed));
    try std.testing.expectEqual(@as(usize, 0), Callback.calls);
    try std.testing.expectEqual(@as(?[*]u8, null), managed.bytes);

    var event: c_abi.PancakeEvent = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_ERR_WOULD_BLOCK, c_abi.pancake_peer_poll_event(peer, &event));

    // Step moves the fed frame into the surfaced event; nothing is released yet.
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_step(peer));
    try std.testing.expectEqual(@as(usize, 0), Callback.calls);

    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    try std.testing.expectEqual(c_abi.PANCAKE_EVENT_ABORT, event.kind);
    try std.testing.expectEqualStrings("<8'op:abort3\"bye>", event.frame.bytes.?[0..event.frame.len]);

    // Releasing the event releases the original fed frame exactly once.
    c_abi.pancake_event_release(&event);
    try std.testing.expectEqual(@as(usize, 1), Callback.calls);
    c_abi.pancake_event_release(&event);
    try std.testing.expectEqual(@as(usize, 1), Callback.calls);
}
