//! Peer-less frame-transport tests over `Reader.fixed` and `std.testing.Reader`,
//! with no sockets. These prove `readFrameFrom` lifts one whole owned frame per envelope, per
//! call across *both* codecs, that a frame larger than the read buffer
//! assembles through the bounded spill (ADR-0041) and the spill frees when it
//! drains, and in particular that a `word`-shaped Cap'n Proto frame is
//! materialized with the 8-byte alignment its shape requires (a byte-aligned
//! copy would fail frame validation and surface every well-formed capnp frame
//! as malformed), including when it assembled in the spill.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const net = glowcap.net;

const zero_pubkey = @as([32]u8, @splat(0));
const zero_sig = @as([64]u8, @splat(0));
const max_frame = 4096;

fn startSessionFrame(allocator: std.mem.Allocator, codec_id: model.CodecId) !glowcap.foundation.Frame {
    return codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.CaptpVersion.v1_0, .{
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

fn startSessionFrameWithDesignator(
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    designator: []const u8,
) !glowcap.foundation.Frame {
    return codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.CaptpVersion.v1_0, .{
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

fn appendStreamFrame(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    _ = try net.appendFrameBytes(list, allocator, bytes);
}

fn expectFramesOneWholeFrame(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, codec_id);
    defer wire.deinit();

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);
    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, wire.bytes());
    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var got = try net.readFrameFrom(&reader, allocator, codec_id, max_frame, &spill);
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
    try std.testing.expectError(error.Closed, net.readFrameFrom(&reader, allocator, codec_id, max_frame, &spill));
}

test "readFrameFrom frames one whole owned Syrup frame" {
    try expectFramesOneWholeFrame(.syrup);
}

test "readFrameFrom frames one whole owned Cap'n Proto frame (8-aligned)" {
    try expectFramesOneWholeFrame(.capnp);
}

test "peer-less framing carries next-profile listen frames for both codecs" {
    const allocator = std.testing.allocator;

    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        var wire = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, .next, .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .near = model.NearRef.object(2) },
            .mode = .shortening_or_settling,
        } });
        defer wire.deinit();

        var stream_bytes: std.ArrayList(u8) = .empty;
        defer stream_bytes.deinit(allocator);
        try appendStreamFrame(&stream_bytes, allocator, wire.bytes());
        var reader = std.Io.Reader.fixed(stream_bytes.items);
        var spill: net.Spill = .{};
        defer spill.deinit(allocator);

        var got = try net.readFrameFrom(&reader, allocator, codec_id, max_frame, &spill);
        defer got.deinit();
        try std.testing.expectEqualSlices(u8, wire.bytes(), got.bytes());
        const body = try codec.dispatch.decodeBodyForProfile(codec_id, .next, got.view());
        try std.testing.expectEqual(model.ListenMode.shortening_or_settling, body.listen.mode);
    }
}

test "peer-less framing carries next-profile deliver frames for both codecs" {
    const allocator = std.testing.allocator;

    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        var wire = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(3) },
            .args = &.{.{ .integer = 8 }},
            .answer = .from(5),
            .resolve_me_desc = .{ .near = model.NearRef.object(9) },
        } });
        defer wire.deinit();

        var stream_bytes: std.ArrayList(u8) = .empty;
        defer stream_bytes.deinit(allocator);
        try appendStreamFrame(&stream_bytes, allocator, wire.bytes());
        var reader = std.Io.Reader.fixed(stream_bytes.items);
        var spill: net.Spill = .{};
        defer spill.deinit(allocator);

        var got = try net.readFrameFrom(&reader, allocator, codec_id, max_frame, &spill);
        defer got.deinit();
        try std.testing.expectEqualSlices(u8, wire.bytes(), got.bytes());
        const body = try codec.dispatch.decodeBodyForProfile(codec_id, .next, got.view());
        try std.testing.expectEqual(model.AnswerPosition.from(5), body.deliver.answer.?);
    }
}

test "readFrameFrom frames each frame of a concatenation in order" {
    const allocator = std.testing.allocator;

    var f1 = try startSessionFrame(allocator, .capnp);
    defer f1.deinit();
    var f2 = try startSessionFrame(allocator, .capnp);
    defer f2.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, f1.bytes());
    try appendStreamFrame(&stream_bytes, allocator, f2.bytes());

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);
    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var g1 = try net.readFrameFrom(&reader, allocator, .capnp, max_frame, &spill);
    defer g1.deinit();
    try std.testing.expectEqualSlices(u8, f1.bytes(), g1.bytes());

    var g2 = try net.readFrameFrom(&reader, allocator, .capnp, max_frame, &spill);
    defer g2.deinit();
    try std.testing.expectEqualSlices(u8, f2.bytes(), g2.bytes());

    try std.testing.expectError(error.Closed, net.readFrameFrom(&reader, allocator, .capnp, max_frame, &spill));
}

test "readFrameFrom surfaces a mid-frame EOF as TruncatedFrame" {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, .syrup);
    defer wire.deinit();

    // One whole frame then the first half of another: reading the whole frame
    // frees buffer room, so the trailing partial hits a genuine mid-frame EOF
    // (rather than the `Reader.fixed` full-buffer artifact).
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, wire.bytes());
    const half = framed.items[0 .. framed.items.len / 2];
    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, wire.bytes());
    try stream_bytes.appendSlice(allocator, half);

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);
    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var first = try net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill);
    first.deinit();

    try std.testing.expectError(error.TruncatedFrame, net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill));
}

fn expectAssemblesThroughSpill(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;

    var f1 = try startSessionFrame(allocator, codec_id);
    defer f1.deinit();
    var f2 = try startSessionFrame(allocator, codec_id);
    defer f2.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, f1.bytes());
    try appendStreamFrame(&stream_bytes, allocator, f2.bytes());

    // A 16-byte read buffer: both frames outgrow it, so each assembles in the
    // spill, and the second frame's first bytes ride in as the first frame's
    // spill leftover (the compaction path).
    var read_buf: [16]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = stream_bytes.items }});
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    var g1 = try net.readFrameFrom(&small.interface, allocator, codec_id, max_frame, &spill);
    defer g1.deinit();
    try std.testing.expectEqualSlices(u8, f1.bytes(), g1.bytes());

    var g2 = try net.readFrameFrom(&small.interface, allocator, codec_id, max_frame, &spill);
    defer g2.deinit();
    try std.testing.expectEqualSlices(u8, f2.bytes(), g2.bytes());

    // A word frame that assembled in the spill must still come out 8-aligned.
    if (codec.dispatch.frameShape(codec_id).? == .word) {
        try std.testing.expect(std.mem.isAligned(@intFromPtr(g1.bytes().ptr), 8));
        try std.testing.expect(std.mem.isAligned(@intFromPtr(g2.bytes().ptr), 8));
    }

    // The spill drains and frees once nothing is mid-flight.
    try std.testing.expect(!spill.isActive());
    try std.testing.expectEqual(@as(usize, 0), spill.buf.len);

    try std.testing.expectError(error.Closed, net.readFrameFrom(&small.interface, allocator, codec_id, max_frame, &spill));
}

test "readFrameFrom assembles Syrup frames larger than the read buffer through the spill" {
    try expectAssemblesThroughSpill(.syrup);
}

test "readFrameFrom assembles Cap'n Proto frames larger than the read buffer through the spill" {
    try expectAssemblesThroughSpill(.capnp);
}

test "readFrameFrom surfaces an over-cap frame as FrameTooLarge" {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, .syrup);
    defer wire.deinit();

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);
    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, wire.bytes());
    var reader = std.Io.Reader.fixed(stream_bytes.items);
    // A cap far below the frame: cap-on-parse rejects it.
    try std.testing.expectError(error.FrameTooLarge, net.readFrameFrom(&reader, allocator, .syrup, 8, &spill));
}

test "Spill absorbBytes concatenates in order and an empty absorb leaves it unallocated" {
    const allocator = std.testing.allocator;

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try std.testing.expect(!spill.isActive());
    try spill.absorbBytes(allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), spill.buf.len);

    try spill.absorbBytes(allocator, &[_]u8{ 1, 2, 3 });
    try spill.absorbBytes(allocator, &[_]u8{ 4, 5, 6 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6 }, spill.bytes());
}

test "Spill consume compacts the remainder forward and releases the storage on full drain" {
    const allocator = std.testing.allocator;

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try spill.absorbBytes(allocator, &[_]u8{ 1, 2, 3, 4, 5 });
    try spill.absorbBytes(allocator, &[_]u8{ 6, 7, 8, 9, 10 });

    // A partial consume keeps the spill live and moves the tail to the front.
    spill.consume(allocator, 3, net.spill_retain_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5, 6, 7, 8, 9, 10 }, spill.bytes());
    try std.testing.expect(spill.isActive());

    // Consuming the rest frees the storage outright, not just the length.
    spill.consume(allocator, 7, net.spill_retain_bytes);
    try std.testing.expect(!spill.isActive());
    try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
}

test "Spill absorb moves a reader's buffered bytes and leaves the reader empty" {
    const allocator = std.testing.allocator;

    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var reader = std.Io.Reader.fixed(&data);

    try net.absorbFrom(&spill, allocator, &reader);
    try std.testing.expectEqualSlices(u8, &data, spill.bytes());
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

test "readFrameFrom accepts a length prefix and body split one byte at a time" {
    const allocator = std.testing.allocator;
    var wire = try startSessionFrameWithDesignator(allocator, .syrup, &(@as([64]u8, @splat('a'))));
    defer wire.deinit();
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, wire.bytes());

    var read_buf: [1]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = framed.items }});
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    var got = try net.readFrameFrom(&small.interface, allocator, .syrup, max_frame, &spill);
    defer got.deinit();
    try std.testing.expectEqualSlices(u8, wire.bytes(), got.bytes());
}

test "writeFrameTo matches Goblins Syrup byte-string framing exactly" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try net.writeFrameTo(&writer, "<7'op:foo>");

    try std.testing.expectEqualStrings("10:<7'op:foo>", writer.buffered());
}

test "readFrameFrom rejects malformed outer length syntax" {
    const allocator = std.testing.allocator;
    const malformed = [_][]const u8{ ":x", "x:thing", "01:x" };
    for (malformed) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        var spill: net.Spill = .{};
        defer spill.deinit(allocator);
        try std.testing.expectError(
            error.MalformedFrame,
            net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill),
        );
    }
}

test "readFrameFrom rejects a declared outer length over the frame cap" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed("9:x");
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try std.testing.expectError(
        error.FrameTooLarge,
        net.readFrameFrom(&reader, allocator, .syrup, 8, &spill),
    );
}

test "readFrameFrom reports EOF inside a declared outer body as truncated" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed("10:abc");
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try std.testing.expectError(
        error.TruncatedFrame,
        net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill),
    );
}

test "readFrameFrom lifts the envelope's body whole and the peer refuses a body of two frames" {
    const allocator = std.testing.allocator;
    var first = try startSessionFrame(allocator, .syrup);
    defer first.deinit();
    var second = try startSessionFrame(allocator, .syrup);
    defer second.deinit();

    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(allocator);
    try inner.appendSlice(allocator, first.bytes());
    try inner.appendSlice(allocator, second.bytes());
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, inner.items);

    var reader = std.Io.Reader.fixed(framed.items);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);
    var frame = try net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill);
    try std.testing.expectEqualSlices(u8, inner.items, frame.bytes());
    var peer = glowcap.ocapn.engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.feedOwned(frame);
    try std.testing.expectError(error.MalformedFrame, peer.step());
}
