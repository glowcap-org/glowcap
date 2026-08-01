//! Peer-less frame-transport tests over `Reader.fixed` and `std.testing.Reader`,
//! with no sockets. These prove `readFrameFrom` frames one whole owned frame per
//! call across *both* codecs, that a frame larger than the read buffer
//! assembles through the bounded spill (ADR-0041) and the spill frees when it
//! drains, and in particular that a `word`-shaped Cap'n Proto frame is
//! materialized with the 8-byte alignment its shape requires (a byte-aligned
//! copy would fail frame validation and surface every well-formed capnp frame
//! as malformed), including when it assembled in the spill.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const net = pancake.net;

const zero_pubkey = [_]u8{0} ** 32;
const zero_sig = [_]u8{0} ** 64;
const max_frame = 4096;

fn startSessionFrame(allocator: std.mem.Allocator, codec_id: model.CodecId) !pancake.foundation.Frame {
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
) !pancake.foundation.Frame {
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

fn expectFramesOneWholeFrame(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;

    var wire = try startSessionFrame(allocator, codec_id);
    defer wire.deinit();

    var spill: net.Spill = .{};
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);
    var reader = std.Io.Reader.fixed(wire.bytes());

    var got = try net.readFrameFrom(&reader, allocator, codec_id, max_frame, &spill, &scan);
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
    try std.testing.expectError(error.Closed, net.readFrameFrom(&reader, allocator, codec_id, max_frame, &spill, &scan));
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

    var spill: net.Spill = .{};
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);
    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var g1 = try net.readFrameFrom(&reader, allocator, .capnp, max_frame, &spill, &scan);
    defer g1.deinit();
    try std.testing.expectEqualSlices(u8, f1.bytes(), g1.bytes());

    var g2 = try net.readFrameFrom(&reader, allocator, .capnp, max_frame, &spill, &scan);
    defer g2.deinit();
    try std.testing.expectEqualSlices(u8, f2.bytes(), g2.bytes());

    try std.testing.expectError(error.Closed, net.readFrameFrom(&reader, allocator, .capnp, max_frame, &spill, &scan));
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

    var spill: net.Spill = .{};
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);
    var reader = std.Io.Reader.fixed(stream_bytes.items);

    var first = try net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill, &scan);
    first.deinit();

    try std.testing.expectError(error.TruncatedFrame, net.readFrameFrom(&reader, allocator, .syrup, max_frame, &spill, &scan));
}

fn expectAssemblesThroughSpill(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;

    var f1 = try startSessionFrame(allocator, codec_id);
    defer f1.deinit();
    var f2 = try startSessionFrame(allocator, codec_id);
    defer f2.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try stream_bytes.appendSlice(allocator, f1.bytes());
    try stream_bytes.appendSlice(allocator, f2.bytes());

    // A 16-byte read buffer: both frames outgrow it, so each assembles in the
    // spill, and the second frame's first bytes ride in as the first frame's
    // spill leftover (the compaction path).
    var read_buf: [16]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = stream_bytes.items }});
    var spill: net.Spill = .{};
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);

    var g1 = try net.readFrameFrom(&small.interface, allocator, codec_id, max_frame, &spill, &scan);
    defer g1.deinit();
    try std.testing.expectEqualSlices(u8, f1.bytes(), g1.bytes());

    var g2 = try net.readFrameFrom(&small.interface, allocator, codec_id, max_frame, &spill, &scan);
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

    try std.testing.expectError(error.Closed, net.readFrameFrom(&small.interface, allocator, codec_id, max_frame, &spill, &scan));
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
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);
    var reader = std.Io.Reader.fixed(wire.bytes());
    // A cap far below the frame: cap-on-parse rejects it.
    try std.testing.expectError(error.FrameTooLarge, net.readFrameFrom(&reader, allocator, .syrup, 8, &spill, &scan));
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

test "readFrameFrom carries its frame scan across reads instead of re-walking" {
    const allocator = std.testing.allocator;
    // A frame arriving a read at a time is the ordinary case on a socket, and
    // walking it from byte zero on every read is quadratic in its size — the
    // shape a partner can buy by dribbling one big frame. The scan makes the
    // walk resumable, so what this pins is that the reader actually carries one:
    // after a long incomplete prefix, the cursor is deep inside the supply
    // rather than back at the start.
    //
    // The frame is grown past the scan threshold by its designator and then cut
    // short of its trailing signature, so every element the scan can step over
    // is present and only the last one is missing.
    var wire = try startSessionFrameWithDesignator(allocator, .syrup, &([_]u8{'a'} ** 6000));
    defer wire.deinit();
    const truncated = wire.bytes()[0 .. wire.bytes().len - 40];
    try std.testing.expect(truncated.len > codec.framing.scan_threshold_bytes);

    // A cap of its own: the file-wide `max_frame` is the scan threshold itself,
    // which would refuse this prefix for size before the scan could matter.
    const scan_max_frame: usize = 1 << 20;
    var read_buf: [64]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = truncated }});
    var spill: net.Spill = .{};
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);

    // The frame never finishes, so the stream ends mid-frame.
    try std.testing.expectError(
        error.TruncatedFrame,
        net.readFrameFrom(&small.interface, allocator, .syrup, scan_max_frame, &spill, &scan),
    );
    // The scan walked the prefix once and kept its place: without it the cursor
    // would still be at zero and every read would have re-walked from there.
    try std.testing.expect(scan.cursor > codec.framing.scan_threshold_bytes);
    try std.testing.expect(scan.depth > 0);
}

test "a finished frame resets the scan, so the next one still resumes" {
    const allocator = std.testing.allocator;
    // A finished frame settles the scan, and a settled scan answers `ready` to
    // everything from then on. So a reset that never happens does not corrupt
    // framing — it silently switches the scan off, and every later frame is
    // walked from its first byte on every read again, which is the quadratic
    // this exists to remove. No assertion on the frames that come back can see
    // that, which is why this one reads the scan itself.
    var first = try startSessionFrameWithDesignator(allocator, .syrup, &([_]u8{'a'} ** 6000));
    defer first.deinit();
    var second = try startSessionFrameWithDesignator(allocator, .syrup, &([_]u8{'b'} ** 6000));
    defer second.deinit();
    try std.testing.expect(first.bytes().len > codec.framing.scan_threshold_bytes);

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try stream_bytes.appendSlice(allocator, first.bytes());
    try stream_bytes.appendSlice(allocator, second.bytes());

    const big_cap: usize = 1 << 20;
    var read_buf: [512]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = stream_bytes.items }});
    var spill: net.Spill = .{};
    var scan: net.StreamScan = .{};
    defer spill.deinit(allocator);

    var got_first = try net.readFrameFrom(&small.interface, allocator, .syrup, big_cap, &spill, &scan);
    defer got_first.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes(), got_first.bytes());

    // The first frame is done, so the scan must be back to where a fresh one
    // starts, ready to resume through the second frame rather than switched off.
    try std.testing.expect(!scan.settled);
    try std.testing.expectEqual(@as(usize, 0), scan.cursor);
    try std.testing.expectEqual(@as(u32, 0), scan.depth);

    var got_second = try net.readFrameFrom(&small.interface, allocator, .syrup, big_cap, &spill, &scan);
    defer got_second.deinit();
    try std.testing.expectEqualSlices(u8, second.bytes(), got_second.bytes());
    try std.testing.expect(!scan.settled);
}
