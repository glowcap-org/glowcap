//! The contract a hand-rolled completion-loop adapter depends on.
//!
//! A completion loop (io_uring / kqueue / IOCP) owns a bounded per-connection
//! byte buffer, receives reads of *arbitrary* size, and must apply whole frames
//! out of that buffer without a `std.Io.Reader` underneath it. The seam for
//! that is `net.recvOuterPrefix` (apply one envelope off a borrowed prefix,
//! report bytes consumed or `.incomplete`, refuse a declared length over the
//! cap before its body arrives), `Peer.step` (encode queued sends), and
//! `Peer.takeOutbound` (pull owned outbound frames). The envelope owns the
//! boundary, and the peer's one parse at admission is the validation, so a
//! body that is not exactly one frame is refused at the door with the same
//! typed abort a decoder refusal projects. These tests drive that seam with
//! no `std.Io` and no socket, the way the loop does, so the contract is pinned
//! apart from the loop: arbitrary chunk boundaries apply each frame exactly
//! once, the unconsumed tail stays valid for the next read, and compaction
//! drains several frames from one buffer. If a refactor breaks the seam, these
//! fail before the loop's own tests do.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const net = glowcap.net;

/// A no-answer (`#f` answer position) `op:deliver` to live local export 7, the
/// fire-and-forget one-way send. With no answer position it installs no inbound
/// answer row, so re-applying it is idempotent on the session tables and a steady
/// stream of them never errors. A distinct-answer deliver would instead trip the
/// live-answer-reuse refusal in `validateInboundDeliverAny` the second time the
/// same position arrived, which is a real protocol violation, not a test concern.
const deliver_to_export7 = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// `frame` as a byte stream carries it: inside one Syrup byte-string envelope.
fn enveloped(comptime frame: []const u8) *const [envelopedLen(frame)]u8 {
    return std.fmt.comptimePrint("{d}:", .{frame.len}) ++ frame;
}

fn envelopedLen(comptime frame: []const u8) usize {
    return std.fmt.comptimePrint("{d}:", .{frame.len}).len + frame.len;
}

/// Apply every whole envelope currently buffered, compacting the unconsumed
/// tail to the front of `buf`, exactly the loop's inner drain. Returns the
/// number of frames applied and the new valid length.
fn drainBuffered(peer: *engine.Peer, buf: []u8, valid_in: usize) !struct { applied: usize, valid: usize } {
    var valid = valid_in;
    var applied: usize = 0;
    while (valid > 0) {
        switch (try net.recvOuterPrefix(peer, buf[0..valid])) {
            .incomplete => break,
            .consumed => |n| {
                applied += 1;
                std.mem.copyForwards(u8, buf[0 .. valid - n], buf[n..valid]);
                valid -= n;
            },
        }
    }
    return .{ .applied = applied, .valid = valid };
}

fn drainDeliverEvents(peer: *engine.Peer) !usize {
    var events: usize = 0;
    while (peer.pollEvent()) |ev_in| {
        var ev = ev_in;
        defer ev.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, ev.kind());
        events += 1;
    }
    return events;
}

/// The abort a refusal at the door projects, committed straight to outbound.
fn expectAbortQueued(peer: *engine.Peer, kind: model.AbortKind) !void {
    const abort = peer.lastAbort() orelse return error.NoAbortRecorded;
    try std.testing.expectEqual(kind, abort.kind);
    var out = peer.takeOutbound() orelse return error.NoAbortFrameQueued;
    defer out.deinit();
    try std.testing.expect(out.bytes().len > 0);
}

test "completion seam: a frame delivered one byte at a time applies exactly once" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    var buf: [256]u8 = undefined;
    var valid: usize = 0;
    var applied_total: usize = 0;
    var events_total: usize = 0;

    // Each iteration is one single-byte "read completion": append, then apply
    // whatever is now whole. Every strict prefix must be `.incomplete` (no error,
    // no state change) until the final byte completes the envelope.
    for (enveloped(deliver_to_export7)) |byte| {
        buf[valid] = byte;
        valid += 1;
        const drained = try drainBuffered(&peer, &buf, valid);
        valid = drained.valid;
        applied_total += drained.applied;
        events_total += try drainDeliverEvents(&peer);
    }

    try std.testing.expectEqual(@as(usize, 1), applied_total);
    try std.testing.expectEqual(@as(usize, 1), events_total);
    try std.testing.expectEqual(@as(usize, 0), valid); // tail fully consumed

    // A deliver to a live export surfaces an event for the application; the core
    // queues no automatic outbound, so the loop arms no write.
    while ((try peer.step()) != .idle) {}
    try std.testing.expect(peer.takeOutbound() == null);
}

test "completion seam: two frames in one read drain via compaction" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = enveloped(deliver_to_export7) ++ enveloped(deliver_to_export7);
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const drained = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 2), drained.applied);
    try std.testing.expectEqual(@as(usize, 0), drained.valid);
    try std.testing.expectEqual(@as(usize, 2), try drainDeliverEvents(&peer));
}

test "completion seam: a deliver with no arguments applies off a stream prefix" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = enveloped("<10'op:deliver<11'desc:export7+>[]ff>");
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const drained = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 1), drained.applied);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));
}

test "completion seam: a frame plus a partial next frame leaves the tail buffered" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // One whole envelope followed by a strict prefix of the next: the loop
    // applies the first and keeps the partial tail for the following read.
    const whole = enveloped(deliver_to_export7);
    const partial = whole[0 .. whole.len - 3];
    const wire = whole ++ partial;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const first = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 1), first.applied);
    try std.testing.expectEqual(partial.len, first.valid); // partial tail retained, intact
    try std.testing.expectEqualStrings(partial, buf[0..first.valid]);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));

    // Append the three missing bytes and the second frame completes.
    const rest = whole[whole.len - 3 ..];
    @memcpy(buf[first.valid .. first.valid + rest.len], rest);
    const second = try drainBuffered(&peer, &buf, first.valid + rest.len);
    try std.testing.expectEqual(@as(usize, 1), second.applied);
    try std.testing.expectEqual(@as(usize, 0), second.valid);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));
}

test "completion seam: the event borrows the retained frame, never the loop's buffer" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = enveloped(deliver_to_export7);
    var buf: [wire.len]u8 = undefined;
    @memcpy(&buf, wire);
    const drained = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 1), drained.applied);
    // A pool buffer is recycled the moment the completion returns, before the
    // application drains the event.
    @memset(&buf, 'x');

    var event = peer.pollEvent() orelse return error.TestUnexpectedResult;
    defer event.deinit();
    var args = event.view().deliver.args.iterator();
    const first = (try args.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", first.bytes);
}

test "completion seam: a declared length over the cap is refused before its body arrives" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = 8;

    // The envelope declares ten bytes against an eight-byte budget, so the
    // frame it carries can never fit however many more bytes arrive. Nothing
    // of the body has been read.
    try std.testing.expectError(error.FrameTooLarge, net.recvOuterPrefix(&peer, "10:<10'op"));
    // And the partner is told. Refusing is what stops a partner growing a
    // consumer's pending buffer without end.
    try expectAbortQueued(&peer, .resource_exhausted);
}

test "completion seam: a declared length exactly at the cap is admissible, one over is not" {
    const whole = enveloped(deliver_to_export7);
    const body_len = deliver_to_export7.len;

    // At the cap, a partial body is incomplete, and the whole body applies.
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    peer.session_state.limits.max_frame_bytes = body_len;
    try std.testing.expectEqual(net.RecvStream.incomplete, try net.recvOuterPrefix(&peer, whole[0 .. whole.len - 1]));
    try std.testing.expect(peer.lastAbort() == null);
    try std.testing.expectEqual(net.RecvStream{ .consumed = whole.len }, try net.recvOuterPrefix(&peer, whole));
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));

    // One byte less of budget and the same declaration is refused.
    var tight = engine.Peer.init(std.testing.allocator);
    defer tight.deinit();
    tight.session_state.limits.max_frame_bytes = body_len - 1;
    try std.testing.expectError(error.FrameTooLarge, net.recvOuterPrefix(&tight, whole));
    try expectAbortQueued(&tight, .resource_exhausted);
}

test "completion seam: an envelope whose body is not exactly one frame is refused at the door" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Two valid frames inside one envelope. The envelope is well formed, so the
    // refusal is the peer's one parse at admission finding trailing bytes.
    const wire = enveloped(deliver_to_export7 ++ deliver_to_export7);
    try std.testing.expectError(error.MalformedFrame, net.recvOuterPrefix(&peer, wire));
    try std.testing.expect(peer.lastAbort() != null);
    try std.testing.expectEqual(@as(usize, 0), try drainDeliverEvents(&peer));

    // A truncated body under a well-formed envelope is refused the same way.
    var cut = engine.Peer.init(std.testing.allocator);
    defer cut.deinit();
    try cut.session_state.registerExport(.from(7));
    try std.testing.expectError(error.MalformedFrame, net.recvOuterPrefix(&cut, enveloped(deliver_to_export7[0 .. deliver_to_export7.len - 1])));
    try std.testing.expect(cut.lastAbort() != null);
}

test "whole-frame ingress refuses over-cap borrowed and owned frames on both codecs" {
    const allocator = std.testing.allocator;
    for ([_]model.CodecId{ .syrup, .capnp }) |encoding| {
        for ([_]bool{ false, true }) |owned| {
            var peer = engine.Peer.init(allocator);
            defer peer.deinit();
            peer.session_state.codec = encoding;
            try peer.session_state.registerExport(.from(7));
            var frame = try codec.dispatch.encodeMessageForProfile(encoding, allocator, .v1_0, .{ .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &.{.{ .string = "hello" }},
                .answer = null,
            } });
            peer.session_state.limits.max_frame_bytes = frame.bytes().len - 1;
            if (owned) {
                // Admission consumes ownership even when it refuses the frame.
                try std.testing.expectError(error.FrameTooLarge, peer.feedOwned(frame));
            } else {
                defer frame.deinit();
                try std.testing.expectError(error.FrameTooLarge, peer.recvBorrowed(frame.view()));
            }
            try std.testing.expect(peer.sessionIsClosed());
            try std.testing.expect(!peer.hasEvent());
            try std.testing.expectEqual(@as(usize, 0), peer.session_state.inbound_answers.len());
            try std.testing.expectEqualStrings("FrameTooLarge", peer.lastAbort().?.error_name);
        }
    }
}

test "whole-frame ingress accepts the exact cap and rechecks queued frames" {
    for ([_]model.CodecId{ .syrup, .capnp }) |encoding| {
        for ([_]bool{ false, true }) |owned| {
            var peer = engine.Peer.init(std.testing.allocator);
            defer peer.deinit();
            peer.session_state.codec = encoding;
            try peer.session_state.registerExport(.from(7));
            var frame = try codec.dispatch.encodeMessageForProfile(encoding, std.testing.allocator, .v1_0, .{ .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &.{.{ .string = "hello" }},
            } });
            peer.session_state.limits.max_frame_bytes = frame.bytes().len;
            if (owned) {
                try peer.feedOwned(frame);
                try peer.stepToIdle();
            } else {
                defer frame.deinit();
                try peer.recvBorrowed(frame.view());
            }
            try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));
        }
        var peer = engine.Peer.init(std.testing.allocator);
        defer peer.deinit();
        peer.session_state.codec = encoding;
        try peer.session_state.registerExport(.from(7));
        const frame = try codec.dispatch.encodeMessageForProfile(encoding, std.testing.allocator, .v1_0, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{},
        } });
        const smaller_cap = frame.bytes().len - 1;
        try peer.feedOwned(frame);
        peer.session_state.limits.max_frame_bytes = smaller_cap;
        try std.testing.expectError(error.FrameTooLarge, peer.step());
        try std.testing.expect(peer.sessionIsClosed());
        try std.testing.expect(!peer.hasEvent());
    }
}

test "whole-frame ingress refuses before copying even under allocation pressure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = deliver_to_export7.len - 1;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.FrameTooLarge, peer.recvBorrowed(.{
        .bytes = deliver_to_export7,
        .shape = .byte,
    }));
    // Encoding the terminal abort can fail locally. The size refusal remains
    // authoritative and the session closes even without an outbound frame.
    try std.testing.expect(peer.sessionIsClosed());
    try std.testing.expectEqualStrings("FrameTooLarge", peer.lastAbort().?.error_name);
    try std.testing.expectEqual(error.OutOfMemory, peer.lastAbort().?.abort_delivery_error.?);
}
