//! The contract a hand-rolled completion-loop adapter depends on.
//!
//! A completion loop (io_uring / kqueue / IOCP) owns a bounded per-connection
//! byte buffer, receives reads of *arbitrary* size, and must apply whole frames
//! out of that buffer without a `std.Io.Reader` underneath it. The Peer seam for
//! that is `recvStreamPrefix` (apply one frame off a borrowed prefix, report
//! bytes consumed or `.incomplete`, fail closed on incomplete-at-cap), `step`
//! (encode queued sends), and `takeOutbound` (pull owned outbound frames). These
//! tests drive that seam with no `std.Io` and no socket, the way the loop will,
//! so the contract is pinned before the loop exists: arbitrary chunk boundaries
//! apply each frame exactly once, the unconsumed tail stays valid for the next
//! read, and compaction drains several frames from one buffer. If a refactor
//! breaks the seam, these fail rather than the future loop.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;

/// A no-answer (`#f` answer position) `op:deliver` to live local export 7, the
/// fire-and-forget one-way send. With no answer position it installs no inbound
/// answer row, so re-applying it is idempotent on the session tables and a steady
/// stream of them never errors. A distinct-answer deliver would instead trip the
/// live-answer-reuse refusal in `validateInboundDeliverAny` the second time the
/// same position arrived, which is a real protocol violation, not a test concern.
const deliver_to_export7 = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// Apply every whole frame currently buffered, compacting the unconsumed tail to
/// the front of `buf`, exactly the loop's inner drain. Returns the number of
/// frames applied and the new valid length.
fn drainBuffered(peer: *engine.Peer, buf: []u8, valid_in: usize) !struct { applied: usize, valid: usize } {
    var valid = valid_in;
    var applied: usize = 0;
    while (valid > 0) {
        switch (try peer.recvStreamPrefix(buf[0..valid])) {
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
    // no state change) until the final byte completes the frame.
    for (deliver_to_export7) |byte| {
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

    const wire = deliver_to_export7 ++ deliver_to_export7;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const drained = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 2), drained.applied);
    try std.testing.expectEqual(@as(usize, 0), drained.valid);
    try std.testing.expectEqual(@as(usize, 2), try drainDeliverEvents(&peer));
}

test "completion seam: a frame plus a partial next frame leaves the tail buffered" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // One whole frame followed by a strict prefix of the next: the loop applies
    // the first and keeps the partial tail for the following read.
    const partial = deliver_to_export7[0 .. deliver_to_export7.len - 3];
    const wire = deliver_to_export7 ++ partial;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const first = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 1), first.applied);
    try std.testing.expectEqual(partial.len, first.valid); // partial tail retained, intact
    try std.testing.expectEqualStrings(partial, buf[0..first.valid]);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));

    // Append the three missing bytes and the second frame completes.
    const rest = deliver_to_export7[deliver_to_export7.len - 3 ..];
    @memcpy(buf[first.valid .. first.valid + rest.len], rest);
    const second = try drainBuffered(&peer, &buf, first.valid + rest.len);
    try std.testing.expectEqual(@as(usize, 1), second.applied);
    try std.testing.expectEqual(@as(usize, 0), second.valid);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));
}

test "completion seam: recvStreamPrefix fails closed on incomplete-at-cap" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = 8;

    // Eight bytes opening a record whose symbol declares ten, so the frame it
    // begins cannot fit an eight-byte budget however many more bytes arrive.
    // The codec refuses that during decode, from the declared length alone.
    const junk = [_]u8{ '<', '1', '0', '\'', 'o', 'p', ':', 'd' };
    try std.testing.expectError(error.FrameTooLarge, peer.recvStreamPrefix(&junk));
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

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;

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

/// A real `op:start-session` grown past the scan threshold by its designator,
/// with only its closing bracket removed. Every element is whole and the record
/// is still open, so the scan walks to the very end of the buffer and parks
/// there with nothing outstanding but the bracket.
///
/// That last part is what makes the fixture: cutting into an element instead
/// would leave the scan waiting on a leaf whose declared length it can compare
/// against the cap, and it hands such a frame straight to the decoder rather
/// than parking. Parking at a boundary is the state in which the buffer can
/// have reached the cap while the scan still says it needs more, which is the
/// only way into the branch under test. Hand-building a record does not reach
/// the scan at all: the decoder refuses a frame whose label is not a known op.
fn truncatedStartSession(allocator: std.mem.Allocator, designator: []const u8) ![]u8 {
    const zero_pubkey = @as([32]u8, @splat(0));
    const zero_sig = @as([64]u8, @splat(0));
    var frame = try codec.dispatch.encodeMessageForProfile(.syrup, allocator, model.CaptpVersion.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey },
            .acceptable_location = .{
                .transport = "memory",
                .designator = designator,
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &zero_sig },
        },
    });
    defer frame.deinit();
    const whole = frame.bytes();
    return allocator.dupe(u8, whole[0 .. whole.len - 1]);
}

test "the scan branch reports incomplete while a stalled frame is still under the cap" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = 1 << 20;

    // Past the scan threshold, so the scan is consulted at all. Every test in
    // this tree that reaches `FrameTooLarge` uses a cap of 8 or 64 bytes, far
    // under that threshold, so none of them enters this branch.
    const bytes = try truncatedStartSession(allocator, &(@as([6000]u8, @splat('a'))));
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > codec.framing.scan_threshold_bytes);

    try std.testing.expectEqual(engine.Peer.RecvStream.incomplete, try peer.recvStreamPrefix(bytes));
    // The decoder would also have said `incomplete`, so the outcome alone does
    // not show the scan ran. What shows it is the peer's own cursor: it walked
    // the prefix and kept its place, so the next read is cheap.
    try std.testing.expect(peer.stream_scan.cursor > codec.framing.scan_threshold_bytes);
    // Withholding the decoder is not the same as refusing: nothing was aborted.
    try std.testing.expect(peer.lastAbort() == null);
}

test "the scan branch refuses at the cap with a typed abort, not a silent stall" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const bytes = try truncatedStartSession(allocator, &(@as([6000]u8, @splat('a'))));
    defer allocator.free(bytes);
    // The buffer has arrived exactly at the cap with the frame still open, so
    // it can never complete within it. The cap has to sit at or above where the
    // scan parks: past that point the scan hands the question to the decoder
    // instead, and this branch never runs.
    peer.session_state.limits.max_frame_bytes = bytes.len;
    try std.testing.expect(peer.session_state.limits.max_frame_bytes > codec.framing.scan_threshold_bytes);

    // A prefix already at the cap can never complete within it. Refusing is
    // what stops a partner growing a consumer's pending buffer without end.
    try std.testing.expectError(error.FrameTooLarge, peer.recvStreamPrefix(bytes));

    // And the partner is told. This branch returned bare for one commit, which
    // left the peer's own contract, a refusal projects a typed abort, broken
    // with nothing in the tree to notice it.
    const abort = peer.lastAbort() orelse return error.NoAbortRecorded;
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.kind);
    // Committed straight to outbound rather than queued for `step`: the session
    // is being refused, so the abort bypasses send accounting.
    var out = peer.takeOutbound() orelse return error.NoAbortFrameQueued;
    defer out.deinit();
    try std.testing.expect(out.bytes().len > 0);
}

test "completion seam: a prefix that is exactly the cap and still open is refused" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // The boundary byte. A codec
    // refuses a prefix *longer* than the cap, so one that is exactly the cap
    // and still open came back `incomplete`, and a consumer that believed it
    // would read past its own limit. The sibling test above is refused a step
    // earlier, by the declared length inside its bytes, so it never reaches
    // this case.
    //
    // Small enough to stay under the scan threshold, so this is the decoder's
    // answer being corrected rather than the withheld-scan arm.
    // `truncatedStartSession` already drops the closing bracket, leaving every
    // element whole and the record open.
    const open = try truncatedStartSession(allocator, "remote");
    defer allocator.free(open);
    try std.testing.expect(open.len < codec.framing.scan_threshold_bytes);

    peer.session_state.limits.max_frame_bytes = open.len;
    try std.testing.expectError(error.FrameTooLarge, peer.recvStreamPrefix(open));

    // And the partner is told, the same as any other refusal here.
    const abort = peer.lastAbort() orelse return error.NoAbortRecorded;
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.kind);

    // One byte of headroom and the same bytes are incomplete, which is
    // what stops this from refusing frames that could still arrive.
    var roomy = engine.Peer.init(allocator);
    defer roomy.deinit();
    roomy.session_state.limits.max_frame_bytes = open.len + 1;
    try std.testing.expectEqual(engine.Peer.RecvStream.incomplete, try roomy.recvStreamPrefix(open));
}
