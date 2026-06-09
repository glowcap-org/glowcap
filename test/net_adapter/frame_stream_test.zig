//! Peer-less frame-transport tests over `Reader.fixed` — no sockets. These prove
//! `readFrameFrom` frames one whole owned frame per call across *both* codecs,
//! and in particular that a `word`-shaped Cap'n Proto frame is materialized with
//! the 8-byte alignment its shape requires (a byte-aligned copy would fail frame
//! validation and surface every well-formed capnp frame as malformed).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const codec = pancake.codec;
const net_adapter = pancake.net_adapter;

const zero_pubkey = [_]u8{0} ** 32;
const zero_sig = [_]u8{0} ** 64;
const max_frame = 4096;

fn startSessionFrame(allocator: std.mem.Allocator, codec_id: model.CodecId) !pancake.foundation.Frame {
    return codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.WireProfile.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey },
            .acceptable_location = .{
                .transport = "memory",
                .designator = "remote",
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &zero_sig },
        },
    });
}

fn expectFramesOneWholeFrame(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, codec_id);
    defer wire.deinit();

    var reader = std.Io.Reader.fixed(wire.bytes());

    var got = try net_adapter.readFrameFrom(&reader, allocator, codec_id, max_frame);
    defer got.deinit();

    // Byte-identical to the encoded frame, and shape-correct.
    try std.testing.expectEqualSlices(u8, wire.bytes(), got.bytes());
    try std.testing.expectEqual(codec.dispatch.frameShape(codec_id).?, got.view().shape);

    // A word frame must be 8-aligned, or `decodeBody` over it would reject it.
    if (codec.dispatch.frameShape(codec_id).? == .word) {
        try std.testing.expect(std.mem.isAligned(@intFromPtr(got.bytes().ptr), 8));
    }
    // The owned frame is a real frame: it decodes back to a body.
    _ = try codec.dispatch.decodeBody(codec_id, got.view());

    // Next read hits a clean boundary EOF.
    try std.testing.expectError(error.Closed, net_adapter.readFrameFrom(&reader, allocator, codec_id, max_frame));
}

test "readFrameFrom frames one whole owned Syrup frame" {
    try expectFramesOneWholeFrame(.syrup);
}

test "readFrameFrom frames one whole owned Cap'n Proto frame (8-aligned)" {
    try expectFramesOneWholeFrame(.capnp);
}

test "readFrameFrom frames each frame of a concatenation in order" {
    const allocator = std.testing.allocator;

    var f1 = try startSessionFrame(allocator, .capnp);
    defer f1.deinit();
    var f2 = try startSessionFrame(allocator, .capnp);
    defer f2.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try stream_bytes.appendSlice(allocator, f1.bytes());
    try stream_bytes.appendSlice(allocator, f2.bytes());

    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var g1 = try net_adapter.readFrameFrom(&reader, allocator, .capnp, max_frame);
    defer g1.deinit();
    try std.testing.expectEqualSlices(u8, f1.bytes(), g1.bytes());

    var g2 = try net_adapter.readFrameFrom(&reader, allocator, .capnp, max_frame);
    defer g2.deinit();
    try std.testing.expectEqualSlices(u8, f2.bytes(), g2.bytes());

    try std.testing.expectError(error.Closed, net_adapter.readFrameFrom(&reader, allocator, .capnp, max_frame));
}

test "readFrameFrom surfaces a mid-frame EOF as TruncatedFrame" {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, .syrup);
    defer wire.deinit();

    // One whole frame then the first half of another: reading the whole frame
    // frees buffer room, so the trailing partial hits a genuine mid-frame EOF
    // (rather than the `Reader.fixed` full-buffer artifact).
    const half = wire.bytes()[0 .. wire.bytes().len / 2];
    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try stream_bytes.appendSlice(allocator, wire.bytes());
    try stream_bytes.appendSlice(allocator, half);

    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var first = try net_adapter.readFrameFrom(&reader, allocator, .syrup, max_frame);
    first.deinit();

    try std.testing.expectError(error.TruncatedFrame, net_adapter.readFrameFrom(&reader, allocator, .syrup, max_frame));
}

test "readFrameFrom surfaces an over-cap frame as FrameTooLarge" {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, .syrup);
    defer wire.deinit();

    var reader = std.Io.Reader.fixed(wire.bytes());
    // A cap far below the frame: cap-on-parse rejects it.
    try std.testing.expectError(error.FrameTooLarge, net_adapter.readFrameFrom(&reader, allocator, .syrup, 8));
}
