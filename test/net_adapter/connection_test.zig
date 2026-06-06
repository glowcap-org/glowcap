//! Connection framing-core tests, driven over `Reader.fixed` / `Writer.fixed`
//! with a real `*engine.Peer` — no sockets. These prove the byte-stream half of
//! the one-parser contract: bytes in, frames out, and every termination
//! condition (graceful close, truncation, malformed, oversize) surfaced as the
//! right typed outcome rather than swallowed.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const syrup = pancake.codec.syrup;
const engine = pancake.engine;
const net_adapter = pancake.net_adapter;

const zero_pubkey = [_]u8{0} ** 32;
const zero_sig = [_]u8{0} ** 64;

/// Encode the stub-key `op:start-session` a negotiating peer admits. The caller
/// owns the returned frame (it backs the inbound byte stream).
fn startSessionFrame(allocator: std.mem.Allocator, designator: []const u8) !pancake.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
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
}

test "pumpOver frames one buffered frame, applies it, then reports graceful close" {
    const allocator = std.testing.allocator;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    var reader = std.Io.Reader.fixed(frame.bytes());
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);

    const first = try net_adapter.pumpOver(&peer, &reader, &writer);
    try std.testing.expect(first == .received);
    try std.testing.expectEqual(frame.bytes().len, first.received);

    var event = peer.pollEvent() orelse return error.TestExpectedEvent;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.start_session, event.kind());

    // Buffer drained, stream ended on a frame boundary → graceful close.
    const second = try net_adapter.pumpOver(&peer, &reader, &writer);
    try std.testing.expect(second == .closed);
}

test "pumpOver frames each frame of a concatenation in order" {
    const allocator = std.testing.allocator;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();

    var f1 = try startSessionFrame(allocator, "a");
    defer f1.deinit();
    var f2 = try startSessionFrame(allocator, "a");
    defer f2.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try stream_bytes.appendSlice(allocator, f1.bytes());
    try stream_bytes.appendSlice(allocator, f2.bytes());

    var reader = std.Io.Reader.fixed(stream_bytes.items);
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);

    const p1 = try net_adapter.pumpOver(&peer, &reader, &writer);
    try std.testing.expect(p1 == .received);
    try std.testing.expectEqual(f1.bytes().len, p1.received);

    // The duplicate start-session is a protocol violation (already received one),
    // so the second frame is *framed* (one parse) but refused by authority —
    // surfaced as a protocol abort, not swallowed.
    try std.testing.expectError(error.ProtocolAbort, net_adapter.pumpOver(&peer, &reader, &writer));
}

test "pumpOver surfaces a mid-frame EOF as TruncatedFrame" {
    const allocator = std.testing.allocator;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    // One whole frame followed by the first half of another.
    const half = frame.bytes()[0 .. frame.bytes().len / 2];
    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try stream_bytes.appendSlice(allocator, frame.bytes());
    try stream_bytes.appendSlice(allocator, half);

    var reader = std.Io.Reader.fixed(stream_bytes.items);
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);

    const first = try net_adapter.pumpOver(&peer, &reader, &writer);
    try std.testing.expect(first == .received);

    // The trailing partial frame cannot complete: EOF mid-frame.
    try std.testing.expectError(error.TruncatedFrame, net_adapter.pumpOver(&peer, &reader, &writer));
}

test "pumpOver surfaces structurally invalid bytes as MalformedFrame" {
    const allocator = std.testing.allocator;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();

    var reader = std.Io.Reader.fixed("<7'op:foo>");
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);

    try std.testing.expectError(error.MalformedFrame, net_adapter.pumpOver(&peer, &reader, &writer));
}

test "pumpOver surfaces an over-cap frame as FrameTooLarge" {
    const allocator = std.testing.allocator;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    // A cap far below the start-session frame: cap-on-parse rejects it.
    peer.session_state.limits.max_frame_bytes = 8;

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    var reader = std.Io.Reader.fixed(frame.bytes());
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);

    try std.testing.expectError(error.FrameTooLarge, net_adapter.pumpOver(&peer, &reader, &writer));
}

test "pumpOver flushes the peer's queued outbound frames" {
    const allocator = std.testing.allocator;

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();

    // A negotiating peer may send its own op:start-session.
    try peer.sendCopying(.{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey },
            .acceptable_location = .{
                .transport = "memory",
                .designator = "local",
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &zero_sig },
        },
    });

    var reader = std.Io.Reader.fixed(&.{}); // nothing inbound
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);

    const progress = try net_adapter.pumpOver(&peer, &reader, &writer);
    try std.testing.expect(progress == .sent);
    try std.testing.expect(progress.sent > 0);
    try std.testing.expectEqual(progress.sent, writer.buffered().len);
}
