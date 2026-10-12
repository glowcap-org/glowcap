//! The stream-plan machinery for the chunk-split target in
//! `test/net/fuzz_test.zig`: a drawn input becomes a geometry and a frame
//! list, the stream is fed in the pieces the plan names, and the oracle
//! asserts every frame comes back whole, in order, once, with the spill
//! bounded the way ADR-0041 promises.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const net = glowcap.net;
const engine = glowcap.ocapn.engine;
const completion = net.completion;

const seeds = @import("../../support/corpus_seeds.zig");

/// Upper bound on one stream plan. Smaller than `max_input`: the input picks
/// frames and a geometry rather than carrying frame bytes itself, so a long
/// input only ever names more frames than the byte budget below admits.
const max_stream_input = 512;

/// The two caps a plan may admit frames under, and the fuzzer picks which. The
/// small one is where the ordinary traffic lives: frames cross the read buffer
/// and nothing else. The large one is above
/// `codec.framing.scan_threshold_bytes`, so a frame or an open record can grow
/// past the point where the codec stops decoding on every read and walks a
/// resumable scan instead.
///
/// Both, rather than only the large one, because the large cap is what a run
/// costs. Below the threshold the decoder re-walks the pending prefix on every
/// read, which is quadratic in the frame size over the read size, and that is
/// the very cost the scan exists to end. Every input paying it would buy the
/// scan-side arms at roughly twenty times the price per input, which the search
/// pays for in inputs it never gets to try.
const small_frame_cap: usize = 1024;
const large_frame_cap: usize = 8192;

/// How often a plan takes the large cap: one input in this many.
const large_cap_in: u8 = 8;

/// Smallest the synthesized frame is built, in bytes. Above the scan threshold
/// with room to spare, so every argument count the plan can choose still crosses
/// it. `ratifyStreamShapes` holds that at both ends.
const big_frame_floor: usize = 4224;

/// Largest read buffer the plan hands the reader, and the most one read may
/// return. Both are drawn from the whole range, so the search reaches
/// byte-at-a-time reads as well as ones that swallow a corpus frame whole. Every
/// corpus frame is longer than this, so a frame always crosses the buffer
/// boundary and goes through the spill for real.
const max_read_len: usize = 96;

/// Chunk boundaries one plan can place. The per-read limit below is what makes
/// reads short, so these only have to be plentiful enough to land at odd
/// offsets.
const max_calls: usize = 128;

/// Frames one stream can carry, and the bytes they may occupy. The budget is
/// what stops a stream of tiny frames from spending the whole run in one input.
const max_stream_frames: usize = 32;
const frames_budget: usize = 8192;

/// The stream one plan feeds, and the synthesized frame it may include. At file
/// scope because a plan hands out slices of them that outlive the builder.
var stream_buf: [frames_budget + large_frame_cap + 32]u8 = undefined;
var big_frame_buf: [large_frame_cap]u8 = undefined;
var frame_spans: [max_stream_frames][]const u8 = undefined;

/// Configuration bytes at the front of an input, before the frame selectors.
const stream_config_bytes: usize = 6;

/// How a stream ends after its last whole frame.
pub const Tail = enum {
    /// Nothing follows, so the reader meets a clean end on a frame boundary.
    clean,
    /// An outer length larger than the frame cap, refused before its body.
    oversize_length,
    /// A whole frame cut off part-way. The stream ends inside a frame, which is
    /// a different condition from ending between two.
    truncated_frame,

    /// What the read after the last whole frame must answer.
    fn verdict(self: Tail) anyerror {
        return switch (self) {
            .clean => error.Closed,
            .oversize_length => error.FrameTooLarge,
            .truncated_frame => error.TruncatedFrame,
        };
    }
};

/// One stream: the geometry the fuzzer chose, the frames it asked for, and the
/// bytes those add up to.
pub const StreamPlan = struct {
    /// Bytes of read buffer the frame reader is given.
    read_len: usize,
    /// Most bytes one read may return, however much room the buffer has. This is
    /// what makes a frame arrive over many short reads.
    per_read: usize,
    /// Bytes per chunk boundary in the stream.
    piece: usize,
    /// The cap frames are admitted under, and so the bound on what the spill may
    /// hold.
    frame_cap: usize,
    tail: Tail,
    /// The bare frames fed, in order. `bytes` carries their outer envelopes.
    frames: []const []const u8,
    /// The whole stream: those frames, then the tail.
    bytes: []const u8,
};

/// The frame part of a corpus seed. `corpus_seeds.seed` prefixes each frame with
/// a little-endian length for the fuzzer's replay framing, so the frame is what
/// follows that prefix.
pub fn corpusFrame(index: usize) []const u8 {
    return seeds.message_seeds[index % seeds.message_seeds.len][4..];
}

pub fn appendOuterFrame(dest: []u8, frame: []const u8) ?usize {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}:", .{frame.len}) catch return null;
    const total = prefix.len + frame.len;
    if (total > dest.len) return null;
    @memcpy(dest[0..prefix.len], prefix);
    @memcpy(dest[prefix.len..total], frame);
    return total;
}

/// An `op:deliver` whose argument list fills about `want` bytes: one whole
/// admissible frame, far larger than any read buffer and larger than the scan
/// threshold, so it is decoded from the spill after a resumable scan has walked
/// it.
///
/// Every fourth argument is a byte string whose payload spells `<`, and that is
/// the point rather than decoration. The scan steps over a length-prefixed leaf
/// by its declared length precisely so a payload byte cannot move its depth. A
/// walk that loses that property counts opens it can never close, withholds the
/// decoder for good, and the frame is refused at the cap instead of returned.
/// Without such a payload the frame cannot tell a correct walk from that one.
pub fn synthesizeDeliver(out: []u8, want: usize) []const u8 {
    const opener = "<10'op:deliver<11'desc:export7+>[";
    const closer = "]42+f>";
    const integer = "1+";
    const opens = "4:<<<<";
    @memcpy(out[0..opener.len], opener);
    var at = opener.len;
    const room = @min(want, out.len);
    var written: usize = 0;
    while (true) : (written += 1) {
        const element = if (written % 4 == 3) opens else integer;
        if (at + element.len + closer.len > room) break;
        @memcpy(out[at..][0..element.len], element);
        at += element.len;
    }
    @memcpy(out[at..][0..closer.len], closer);
    return out[0 .. at + closer.len];
}

/// Read one stream plan out of the drawn input, or null when the input is too
/// short to describe one.
///
/// Every choice comes out of these bytes rather than from a separate draw. A
/// draw made after `smith.slice` has consumed the input answers the same way on
/// every replay, so a saved finding would replay under a geometry the fuzzer
/// never found it with, and for a target whose whole subject is geometry that
/// is the wrong one every time.
pub fn planStream(input: []const u8) ?StreamPlan {
    if (input.len <= stream_config_bytes) return null;

    const read_len = 1 + @as(usize, input[0]) % max_read_len;
    const per_read = 1 + @as(usize, input[1]) % max_read_len;
    const tail: Tail = switch (input[2] % 3) {
        0 => .clean,
        1 => .oversize_length,
        else => .truncated_frame,
    };
    // One byte carries both halves of the large-cap choice, because they only
    // mean anything together: the synthesized frame is admissible under the
    // large cap alone, and the large cap has nothing above the scan threshold to
    // show without it. The argument count keeps the frame over the threshold at
    // the low end and under the cap at the high end; `ratifyStreamShapes` holds
    // both.
    const large = input[3] % large_cap_in == 0;
    const cap = if (large) large_frame_cap else small_frame_cap;
    const big = synthesizeDeliver(&big_frame_buf, big_frame_floor + @as(usize, input[3] / large_cap_in) * 128);

    var at: usize = 0;
    var count: usize = 0;
    for (input[stream_config_bytes..]) |selector| {
        if (count == max_stream_frames) break;
        // One past the corpus selects the synthesized frame, so a stream can
        // mix a frame that crosses every boundary with frames that cross only
        // the read buffer.
        const pick = selector % (seeds.message_seeds.len + 1);
        const synthesized = pick == seeds.message_seeds.len;
        if (synthesized and !large) continue;
        const frame = if (synthesized) big else corpusFrame(pick);
        const framed_len = appendOuterFrame(stream_buf[at..frames_budget], frame) orelse break;
        frame_spans[count] = frame;
        at += framed_len;
        count += 1;
    }

    switch (tail) {
        .clean => {},
        .oversize_length => {
            const prefix = std.fmt.bufPrint(stream_buf[at..], "{d}:", .{cap + 1}) catch return null;
            at += prefix.len;
        },
        .truncated_frame => {
            const frame = corpusFrame(input[4]);
            const keep = 1 + @as(usize, input[5]) % (frame.len - 1);
            var prefix_buf: [32]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "{d}:", .{frame.len}) catch return null;
            @memcpy(stream_buf[at..][0..prefix.len], prefix);
            at += prefix.len;
            @memcpy(stream_buf[at..][0..keep], frame[0..keep]);
            at += keep;
        },
    }

    return .{
        .read_len = read_len,
        .per_read = per_read,
        .piece = 1 + @as(usize, input[1] ^ input[2]) % 251,
        .frame_cap = cap,
        .tail = tail,
        .frames = frame_spans[0..count],
        .bytes = stream_buf[0..at],
    };
}

/// Cut `bytes` into chunk-sized reader calls, returning how many were filled.
/// The pieces are sized so they can span the whole stream: a fixed small piece
/// silently truncates everything past `calls.len` bytes.
pub fn splitStream(bytes: []const u8, calls: []std.testing.Reader.Call, piece: usize) usize {
    const min_piece = std.math.divCeil(usize, bytes.len, calls.len) catch 1;
    const use = @max(piece, @max(min_piece, 1));
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len and count < calls.len) : (count += 1) {
        const end = @min(at + use, bytes.len);
        calls[count] = .{ .buffer = bytes[at..end] };
        at = end;
    }
    return count;
}

/// The spill's boundedness and retention, checked where a caller can see them:
/// between frames.
pub fn expectSpillBounded(spill: *const net.Spill, plan: StreamPlan) !void {
    // A spill that is not accumulating has freed its storage, not merely
    // emptied it. That is the whole reason this is a spill rather than a buffer
    // per connection.
    if (!spill.isActive()) try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
    try std.testing.expect(spill.len <= spill.buf.len);
    // What waits here is one in-flight frame, and the codec refuses a prefix
    // that reaches the cap, so the most that can be waiting is the cap plus the
    // single read that carried the prefix over it.
    const bound = plan.frame_cap + 32 + plan.read_len;
    try std.testing.expect(spill.len <= bound);
    // Capacity doubles when it grows, so it can overshoot what is waiting by up
    // to one doubling and no more.
    try std.testing.expect(spill.buf.len <= 2 * bound);
}

pub fn driveStream(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var raw: [max_stream_input]u8 = undefined;
    const input = raw[0..smith.slice(&raw)];
    const plan = planStream(input) orelse return;

    var read_buf: [max_read_len]u8 = undefined;
    var calls: [max_calls]std.testing.Reader.Call = undefined;
    const call_count = splitStream(plan.bytes, &calls, plan.piece);
    var test_reader = std.testing.Reader.init(read_buf[0..plan.read_len], calls[0..call_count]);
    test_reader.artificial_limit = .limited(plan.per_read);
    const reader = &test_reader.interface;

    var spill: net.Spill = .{};
    defer spill.deinit(gpa);
    var scan: net.StreamScan = .{};

    for (plan.frames, 1..) |expected, nth| {
        var frame = net.readFrameFrom(reader, gpa, .syrup, plan.frame_cap, &spill, &scan) catch |err| {
            // Every frame in the plan is whole and admissible, so a refusal here
            // means bytes went missing between the stream and the parser.
            std.debug.print(
                "frame {d} of {d} was fed whole and came back as {s}\n",
                .{ nth, plan.frames.len, @errorName(err) },
            );
            return err;
        };
        defer frame.deinit();
        try std.testing.expectEqualSlices(u8, expected, frame.bytes());
        try expectSpillBounded(&spill, plan);
    }

    // The read past the last frame. A frame here is a byte the reader invented
    // or read twice, which is why the tail's verdict is asserted rather than
    // merely the absence of a crash.
    if (net.readFrameFrom(reader, gpa, .syrup, plan.frame_cap, &spill, &scan)) |extra| {
        var frame = extra;
        frame.deinit();
        std.debug.print(
            "the stream held {d} frames and a {t} tail, and a further frame was read\n",
            .{ plan.frames.len, plan.tail },
        );
        return error.FrameAfterStreamEnd;
    } else |err| {
        try std.testing.expectEqual(plan.tail.verdict(), err);
    }
    try expectSpillBounded(&spill, plan);
}

/// The geometry this target claims for itself, checked rather than asserted in
/// prose.
///
/// Each of these was wrong at some point in some target's life, and every one of
/// them fails silently: a corpus frame that no longer decodes, a synthesized
/// frame that stops crossing the threshold it exists to cross, or a tail the
/// stream ends before the cap can refuse it, all leave a target that passes
/// while searching a smaller space than its header claims.
pub fn ratifyStreamShapes() !void {
    for (seeds.message_seeds) |entry| {
        const frame = entry[4..];
        // Two bytes at least, so a truncated tail has somewhere to cut, and
        // inside the smaller of the two caps, so every corpus frame is
        // admissible under either.
        try std.testing.expect(frame.len >= 2);
        try std.testing.expect(frame.len <= small_frame_cap);
        var scan: net.StreamScan = .{};
        const prefix = codec.dispatch.framePrefix(.syrup, frame, &scan, small_frame_cap);
        try std.testing.expect(prefix == .complete);
        try std.testing.expectEqual(frame.len, prefix.complete);
    }

    // The synthesized frame, at both ends of the argument count the plan can
    // choose: one whole frame, over the scan threshold, under the large cap.
    for ([_]u8{ 0, 31 }) |step| {
        const big = synthesizeDeliver(&big_frame_buf, big_frame_floor + @as(usize, step) * 128);
        try std.testing.expect(big.len > codec.framing.scan_threshold_bytes);
        try std.testing.expect(big.len <= large_frame_cap);
        var scan: net.StreamScan = .{};
        const prefix = codec.dispatch.framePrefix(.syrup, big, &scan, large_frame_cap);
        try std.testing.expect(prefix == .complete);
        try std.testing.expectEqual(big.len, prefix.complete);
    }

    // The outer length is the byte-stream allocation bound: a declaration over
    // the frame cap is refused before any body bytes arrive.
    for ([_]usize{ small_frame_cap, large_frame_cap }) |cap| {
        var prefix_buf: [32]u8 = undefined;
        const at_cap = try std.fmt.bufPrint(&prefix_buf, "{d}:", .{cap});
        try std.testing.expect(glowcap.net.outerPrefix(at_cap, cap) == .incomplete);
        const over_cap = try std.fmt.bufPrint(&prefix_buf, "{d}:", .{cap + 1});
        try std.testing.expect(glowcap.net.outerPrefix(over_cap, cap) == .too_large);
    }
}
