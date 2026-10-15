//! Frames in flight through the keyed-relay completion adapter: the close
//! choreography against partial and chunked application sends, ping and pong
//! interleaving, inbound fragmentation order, receive cursors, and what
//! cancellation may and may not un-queue. Driven against the same scriptable
//! platform as `keyed_relay_completion_test.zig`
//! (`test/support/keyed_relay_admission.zig`).

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../support/keyed_relay_admission.zig");

const net = glowcap.net;
const keyed_relay = net.relay;

const Io = std.Io;

const frame_cap = admission.frame_cap;
const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;
const startUpgradeRelay = admission.startUpgradeRelay;
const openAdmissionRelay = admission.openAdmissionRelay;

test "keyed-relay partial application send completes only after the frame drains" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitSend(44, fd, "payload");
    backend.platform.pending_send.?.result = 3;

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);
    try std.testing.expect(conn.ws_out_off > 0);
    try std.testing.expect(conn.ws_out_off < conn.ws_out.items.len);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 44), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 7), completions[0].result);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
    try std.testing.expectEqual(@as(usize, 0), conn.ws_out.items.len);
}

test "keyed-relay completion echoes a valid peer close before reporting EOF" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const payload = [_]u8{ 0x03, 0xe8, 'b', 'y', 'e' };
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x88, payload.len });
    try conn.raw_in.appendSlice(backend.allocator, &payload);

    try backend.submitRecv(44, fd);
    try std.testing.expect(conn.close.wire.hasReceived());
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expect(conn.pending.get(.send));
    try std.testing.expectError(error.ConnectionLost, backend.submitSend(46, fd, "late"));
    try std.testing.expectEqual(@as(u8, 0x88), conn.ws_out.items[0]);
    try std.testing.expect(conn.ws_out.items[1] & 0x80 != 0);
    const mask = conn.ws_out.items[2..6];
    for (payload, 0..) |byte, i|
        try std.testing.expectEqual(byte, conn.ws_out.items[6 + i] ^ mask[i % 4]);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 44), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}

test "keyed-relay peer close takes priority over an application send deferred by pong" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    // The ping starts an internal pong send while the close remains buffered.
    // An application write arriving in that window must fail after the pong,
    // never appear on the wire ahead of the close response.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00, 0x88, 0x00 });
    try backend.submitRecv(47, fd);
    const late = "late";
    try backend.submitSend(48, fd, late);
    try std.testing.expectEqual(late.ptr, conn.external_send_remainder.ptr);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 48), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expect(conn.close.wire.hasReceived());
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);

    // The only send now in flight is the close response. Its completion then
    // retires the still-owned receive seat as EOF.
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 47), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}

test "keyed-relay local close releases an application send deferred by pong" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00 });
    try backend.submitRecv(49, fd);
    const retained = "retained-until-close";
    try backend.submitSend(50, fd, retained);
    try std.testing.expectEqual(retained.ptr, conn.external_send_remainder.ptr);

    try backend.submitClose(51, fd);
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
}

test "keyed-relay completion rejects an invalid peer close payload" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x88, 0x02, 0x03, 0xed });
    try backend.submitRecv(45, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 45), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
}

fn expectMaskedBinaryFrame(frame: []const u8, expected: []const u8) !void {
    try std.testing.expect(frame.len >= 6);
    try std.testing.expectEqual(@as(u8, 0x82), frame[0]);
    try std.testing.expect(frame[1] & 0x80 != 0);
    const len7 = frame[1] & 0x7f;
    const mask_at: usize = switch (len7) {
        126 => blk: {
            try std.testing.expect(frame.len >= 8);
            try std.testing.expectEqual(expected.len, std.mem.readInt(u16, frame[2..4], .big));
            break :blk 4;
        },
        127 => blk: {
            try std.testing.expect(frame.len >= 14);
            try std.testing.expectEqual(expected.len, std.mem.readInt(u64, frame[2..10], .big));
            break :blk 10;
        },
        else => blk: {
            try std.testing.expectEqual(expected.len, len7);
            break :blk 2;
        },
    };
    const payload_at = mask_at + 4;
    try std.testing.expectEqual(payload_at + expected.len, frame.len);
    const mask = frame[mask_at..payload_at];
    for (expected, frame[payload_at..], 0..) |want, got, i|
        try std.testing.expectEqual(want, got ^ mask[i % mask.len]);
}

test "keyed-relay completion chunks one borrowed write behind one completion" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes * 2 + 17]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    try backend.submitSend(47, fd, &payload);
    try std.testing.expectEqual(payload[chunk_bytes..].ptr, conn.external_send_remainder.ptr);
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[0..chunk_bytes]);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[chunk_bytes .. chunk_bytes * 2]);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[chunk_bytes * 2 ..]);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 47), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, payload.len), completions[0].result);
    try std.testing.expectEqual(@as(usize, 3), backend.platform.send_submits);
    try std.testing.expect(conn.ws_out.capacity <= frame_cap);
}

test "keyed-relay completion sends zero bytes without a WebSocket frame" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(48, fd, &.{});
    try std.testing.expectEqual(@as(usize, 0), backend.platform.send_submits);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 48), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
}

test "keyed-relay completion answers a retained ping between send chunks" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 3]u8 = undefined;
    @memset(&payload, 0x5a);

    try backend.submitSend(49, fd, &payload);
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00 });
    var completions: [1]net.completion.Completion = undefined;

    // The first data chunk retires into a Pong, even though no application
    // receive seat exists to drive the ordinary receive projector.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u8, 0x8a), conn.ws_out.items[0]);
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);

    // Pong retirement admits the final byte-stream chunk; only that chunk's
    // retirement completes the original write.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try expectMaskedBinaryFrame(conn.ws_out.items, payload[chunk_bytes..]);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 49), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, payload.len), completions[0].result);
}

test "keyed-relay completion honors a retained close between send chunks" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 1]u8 = undefined;
    @memset(&payload, 0x5b);

    try backend.submitSend(50, fd, &payload);
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x88, 0x00 });
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 50), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(@as(u8, 0x88), conn.ws_out.items[0]);
    try std.testing.expect(conn.close.wire.hasReceived());
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);
}

test "keyed-relay completion honors a close behind projected data between chunks" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 1]u8 = undefined;
    @memset(&payload, 0x5d);

    try backend.submitSend(52, fd, &payload);
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'x', 0x88, 0x00 });
    try backend.submitRecv(53, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 53), completions[0].user_data);
    try std.testing.expectEqualStrings("x", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(u64, 52), completions[1].user_data);
    try std.testing.expect(completions[1].result < 0);
    try std.testing.expectEqual(@as(u8, 0x88), conn.ws_out.items[0]);
}

test "keyed-relay completion makes a later chunk submit failure terminal" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const chunk_bytes = frame_cap - keyed_relay.max_header_len;
    var payload: [chunk_bytes + 1]u8 = undefined;
    @memset(&payload, 0x5c);

    try backend.submitSend(51, fd, &payload);
    backend.platform.fail_send = true;
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 51), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(usize, 0), conn.ws_out.items.len);
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);
}

test "keyed-relay does not prefetch an open connection without a receive seat" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(51, fd, "payload");
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 51), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.recv_submits);
}

test "keyed-relay control send retains the receive seat through terminal failure" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    // A server ping immediately followed by binary application bytes. The
    // pong is an internal send, but its lifetime belongs to this receive: the
    // following binary frame must not retire the only Loop-visible seat first.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00, 0x82, 0x01, 'x' });
    try backend.submitRecv(61, fd);
    try std.testing.expectEqual(@as(?u64, 61), conn.external_recv_ud);
    try std.testing.expectEqual(@as(usize, 0), backend.ready.len());
    backend.platform.pending_send.?.result = -1;

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 61), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
}

test "keyed-relay app send during pong keeps the in-flight buffer stable" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x89, 0x00 });
    try backend.submitRecv(71, fd);
    try std.testing.expect(conn.pending.get(.send));
    const in_flight_ptr = conn.ws_out.items.ptr;
    const in_flight_len = conn.ws_out.items.len;

    const payload = "payload";
    try backend.submitSend(72, fd, payload);
    try std.testing.expectEqual(in_flight_ptr, conn.ws_out.items.ptr);
    try std.testing.expectEqual(in_flight_len, conn.ws_out.items.len);
    try std.testing.expectEqual(payload.ptr, conn.external_send_remainder.ptr);

    var completions: [1]net.completion.Completion = undefined;
    // Pong completion frames and arms the deferred application send, but does
    // not report it complete before those bytes reach the platform.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(conn.pending.get(.send));
    try std.testing.expectEqual(@as(usize, 0), conn.external_send_remainder.len);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 72), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 7), completions[0].result);
}

test "keyed-relay completion path enforces WebSocket fragmentation order" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var completions: [1]net.completion.Completion = undefined;

    // A continuation has no authority without a preceding non-final binary
    // frame. Refuse it as a terminal transport fault, not CapTP payload.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x80, 0x01, 'x' });
    try backend.submitRecv(62, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 62), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
}

test "keyed-relay completion path streams a valid fragmented binary message" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var completions: [1]net.completion.Completion = undefined;

    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x02, 0x01, 'a', 0x80, 0x01, 'b' });
    try backend.submitRecv(63, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);

    try backend.submitRecv(64, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "b", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expect(!conn.fragmented);
}

test "keyed-relay completion receive advances a cursor without shifting payload" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var wire: [132]u8 = undefined;
    const header = [_]u8{ 0x82, 126, 0, 128 };
    @memcpy(wire[0..4], &header);
    @memset(wire[4..], 0x5a);
    try conn.raw_in.ensureTotalCapacityPrecise(backend.allocator, wire.len);
    conn.raw_in.appendSliceAssumeCapacity(&wire);

    try backend.submitRecv(65, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 64), completions[0].borrowed.recvBytes().?.len);
    try std.testing.expectEqual(@as(usize, 132), conn.raw_in.items.len);
    try std.testing.expectEqual(@as(usize, 68), conn.raw_in_head);
    backend.recycleBorrowed(completions[0]);

    try backend.submitRecv(66, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 64), completions[0].borrowed.recvBytes().?.len);
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in.items.len);
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in_head);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay retries wrapped-platform recv-buffer starvation" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(71, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(.open, conn.state);
    try std.testing.expectEqual(@as(?u64, 71), conn.external_recv_ud);
    try std.testing.expect(backend.recv_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 1), backend.recv_retries.head);

    backend.platform.emit_recv_no_buffer = false;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_submits);
    try std.testing.expect(backend.recv_retries.contains(conn));

    // Polling cannot manufacture a platform buffer. Returning one is the
    // progress edge that retries every starved receive exactly once.
    backend.recycleBorrowed(.{ .user_data = 0, .result = 0, .borrowed = .recv("x", 42) });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 2), backend.platform.recv_submits);
    try std.testing.expect(!backend.recv_retries.contains(conn));
    try std.testing.expect(conn.pending.get(.recv));
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.tail);
}

test "keyed-relay canceled receive is not rearmed after buffer starvation" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(72, fd);
    try backend.submitCancel(73, 72, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expect(!backend.recv_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);

    backend.platform.emit_recv_no_buffer = false;
    backend.recycleBorrowed(.{ .user_data = 0, .result = 0, .borrowed = .recv("x", 42) });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_submits);
    try std.testing.expect(!conn.pending.get(.recv));
}

test "keyed-relay canceled receive preserves a late platform payload" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    var wire = [_]u8{ 0x82, 0x01, 'a' };
    backend.platform.recv_payload = &wire;

    try backend.submitRecv(76, fd);
    try backend.submitCancel(77, 76, fd);

    // The cancel owes both records before the poll, and they fill the two
    // slots. The late platform payload lands next pass and is kept.
    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in.items.len);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, &wire, conn.raw_in.items);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);

    try backend.submitRecv(78, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 78), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay cancellation removes an already queued receive retry" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(74, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.recv_retries.contains(conn));

    try backend.submitCancel(75, 74, fd);
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expect(!backend.recv_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);

    backend.platform.emit_recv_no_buffer = false;
    backend.recycleBorrowed(.{ .user_data = 0, .result = 0, .borrowed = .recv("x", 42) });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_submits);
    try std.testing.expect(!conn.pending.get(.recv));
}

test "keyed-relay recv starvation after wrapped close still completes close" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(72, fd);
    backend.platform.close_before_recv = true;
    try backend.submitClose(73, fd);

    var completions: [2]net.completion.Completion = undefined;
    // The caller's receive seat is canceled while its wrapped receive remains
    // in flight; the close frame then drains and submits the wrapped close.
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 72), completions[0].user_data);
    try std.testing.expect(conn.pending.get(.recv));
    try std.testing.expectEqual(.in_flight, conn.inner_close);

    // Adversarial order: descriptor close completes before the no-buffer CQE.
    // The latter retires the final operation and must take the common terminal
    // path rather than enqueue a read that a closing connection cannot use.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(.closed, conn.inner_close);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 73), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(u32, 0), backend.recv_retries.head);
}

// --- The loopback scenario -------------------------------------------------
