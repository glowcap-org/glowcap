const std = @import("std");
const pancake = @import("pancake");

const c_abi = @import("c_abi");

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

test "C ABI recv_stream frames a byte stream one frame at a time" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
    defer c_abi.pancake_peer_release(peer);
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_register_export(peer, 7));

    const frame = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>";

    // A partial frame consumes nothing and asks for more bytes.
    var consumed: usize = 123;
    try std.testing.expectEqual(
        c_abi.PANCAKE_ERR_WOULD_BLOCK,
        c_abi.pancake_peer_recv_stream(peer, frame.ptr, frame.len - 3, &consumed),
    );
    try std.testing.expectEqual(@as(usize, 0), consumed);

    // Two whole frames back-to-back: each call consumes exactly one frame.
    const stream = frame ++ frame;
    var offset: usize = 0;
    try std.testing.expectEqual(
        c_abi.PANCAKE_OK,
        c_abi.pancake_peer_recv_stream(peer, stream.ptr + offset, stream.len - offset, &consumed),
    );
    try std.testing.expectEqual(frame.len, consumed);
    offset += consumed;
    try std.testing.expectEqual(
        c_abi.PANCAKE_OK,
        c_abi.pancake_peer_recv_stream(peer, stream.ptr + offset, stream.len - offset, &consumed),
    );
    try std.testing.expectEqual(frame.len, consumed);
    offset += consumed;
    try std.testing.expectEqual(stream.len, offset);

    // Both deliveries surfaced as events.
    var event: c_abi.PancakeEvent = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    try std.testing.expectEqual(c_abi.PANCAKE_EVENT_DELIVER, event.kind);
    c_abi.pancake_event_release(&event);
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    c_abi.pancake_event_release(&event);
}

test "C ABI recv_stream refuses an over-cap frame instead of asking for more bytes" {
    // Every binding accumulates an inbox and keeps reading while recv_stream
    // answers WOULD_BLOCK, so the inbox is bounded only if an over-cap frame
    // is refused as FRAME_TOO_LARGE the moment that is knowable (ADR-0041),
    // both when a length prefix declares past the cap and when an undeclared
    // frame has already buffered past it.
    const allocator = std.testing.allocator;

    // A bytestring argument declaring 2,000,000 bytes — past the 1 MiB default
    // cap — is refused from ~40 bytes of prefix, before those bytes arrive.
    {
        var peer: ?*c_abi.PancakePeer = null;
        try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
        defer c_abi.pancake_peer_release(peer);
        try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_register_export(peer, 7));

        const declared = "<10'op:deliver<11'desc:export7+>[2000000:";
        var consumed: usize = 123;
        try std.testing.expectEqual(
            c_abi.PANCAKE_ERR_FRAME_TOO_LARGE,
            c_abi.pancake_peer_recv_stream(peer, declared.ptr, declared.len, &consumed),
        );
        try std.testing.expectEqual(@as(usize, 0), consumed);
    }

    // An element-by-element frame that never closes: once the buffered prefix
    // crosses the cap the verdict is FRAME_TOO_LARGE, never WOULD_BLOCK.
    {
        var peer: ?*c_abi.PancakePeer = null;
        try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
        defer c_abi.pancake_peer_release(peer);
        try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_register_export(peer, 7));

        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(allocator);
        try prefix.appendSlice(allocator, "<10'op:deliver<11'desc:export7+>[");
        while (prefix.items.len <= 1 << 20) try prefix.appendSlice(allocator, "1+");

        var consumed: usize = 123;
        try std.testing.expectEqual(
            c_abi.PANCAKE_ERR_FRAME_TOO_LARGE,
            c_abi.pancake_peer_recv_stream(peer, prefix.items.ptr, prefix.items.len, &consumed),
        );
        try std.testing.expectEqual(@as(usize, 0), consumed);
    }
}

test "C ABI peer handles borrowed abort frames" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
    defer c_abi.pancake_peer_release(peer);

    const frame = c_abi.PancakeFrame{
        .bytes = "<8'op:abort3\"bye>".ptr,
        .len = "<8'op:abort3\"bye>".len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
    };
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_recv_borrowed(peer, &frame));

    var event: c_abi.PancakeEvent = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_poll_event(peer, &event));
    defer c_abi.pancake_event_release(&event);
    try std.testing.expectEqual(c_abi.PANCAKE_EVENT_ABORT, event.kind);
    try std.testing.expectEqualStrings("<8'op:abort3\"bye>", event.frame.bytes.?[0..event.frame.len]);
}

test "C ABI surfaces the typed cause of a refused frame through last_abort" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
    defer c_abi.pancake_peer_release(peer);

    // No failure yet: the getter reports nothing to read.
    var info: c_abi.PancakeLastAbort = undefined;
    try std.testing.expectEqual(c_abi.PANCAKE_ERR_WOULD_BLOCK, c_abi.pancake_peer_last_abort(peer, &info));

    // Garbage that is not a decodable frame is refused at the codec layer.
    const garbage = "this is not a frame";
    const frame = c_abi.PancakeFrame{
        .bytes = garbage.ptr,
        .len = garbage.len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
    };
    try std.testing.expect(c_abi.pancake_peer_recv_borrowed(peer, &frame) != c_abi.PANCAKE_OK);

    // The flat return code named the family; last_abort names the member.
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_last_abort(peer, &info));
    try std.testing.expectEqual(@as(u32, 0), info.domain); // 0 = codec
    try std.testing.expectEqual(@as(u32, 1), info.has_kind);
    try std.testing.expectEqualStrings("MalformedFrame", info.kind_name.?[0..info.kind_name_len]);
    try std.testing.expectEqualStrings("MalformedFrame", info.error_name.?[0..info.error_name_len]);
}

test "C ABI exposes non-abort events as managed event frames in the negotiated codec" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
    defer c_abi.pancake_peer_release(peer);

    const frame = c_abi.PancakeFrame{
        .bytes = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>".ptr,
        .len = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>".len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_BYTE,
    };
    const runtime_peer: *pancake.ocapn.engine.Peer = @ptrCast(@alignCast(peer.?));
    try runtime_peer.session_state.registerExport(.from(7));
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_recv_borrowed(peer, &frame));

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
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
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
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
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
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
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

test "C ABI owned feed failure consumes the frame exactly once" {
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
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
    defer c_abi.pancake_peer_release(peer);

    var bytes = [_]u8{ 1, 2, 3 };
    var managed = c_abi.PancakeManagedFrame{
        .bytes = bytes[0..].ptr,
        .len = bytes.len,
        .shape = c_abi.PANCAKE_FRAME_SHAPE_WORD,
        .release = Callback.release,
        .private_data = null,
    };

    // A word-shaped frame whose length is not a multiple of 8 is refused, but
    // ownership has already transferred: the library releases the frame through
    // its own callback and clears the caller's struct.
    try std.testing.expectEqual(c_abi.PANCAKE_ERR_INVALID_ARGUMENT, c_abi.pancake_peer_feed_owned(peer, &managed));
    try std.testing.expectEqual(@as(usize, 1), Callback.calls);
    try std.testing.expect(managed.bytes == null);

    // A late release on the cleared struct is the documented no-op.
    c_abi.pancake_managed_frame_release(&managed);
    try std.testing.expectEqual(@as(usize, 1), Callback.calls);
}

test "C ABI recv_stream treats an empty buffer as an incomplete frame" {
    var peer: ?*c_abi.PancakePeer = null;
    try std.testing.expectEqual(c_abi.PANCAKE_OK, c_abi.pancake_peer_new_raw_open(&peer));
    defer c_abi.pancake_peer_release(peer);

    // Zero buffered bytes is semantically "read more", not a bad pointer:
    // (NULL, 0) reports would-block with nothing consumed.
    var consumed: usize = 99;
    try std.testing.expectEqual(
        c_abi.PANCAKE_ERR_WOULD_BLOCK,
        c_abi.pancake_peer_recv_stream(peer, null, 0, &consumed),
    );
    try std.testing.expectEqual(@as(usize, 0), consumed);
}
