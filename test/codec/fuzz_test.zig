//! Hostile-bytes fuzz entrypoints for both codecs.
//!
//! Three `std.testing.fuzz` blocks, one per untrusted-input decode surface:
//! the Syrup streaming framer (`decodePrefix`, cap-on-parse per ADR-0029), the
//! Cap'n Proto borrowed decode plus owned projection (the traversal-budget and
//! pointer-arithmetic paths), and the Syrup owned materializer (`decodeOwned`,
//! the multi-allocation partial-failure cleanup path). Under a plain
//! `zig build test` each block replays its seed corpus (plus an empty input);
//! under `zig build test --fuzz` the same blocks become live fuzzers — no
//! separate build step.
//!
//! The contract per entrypoint: an arbitrary byte string never panics and
//! never leaks (everything runs under `std.testing.allocator`, which fails the
//! test on either), and a successful decode is re-encodable up to the codec's
//! typed refusals — when the re-encode succeeds, one further decode/encode
//! crossing must reproduce the same bytes exactly (the ADR-0010 perspective
//! flip is an involution, so two crossings are a fixed point).
//!
//! Seeds: the checked-in Syrup fixture corpus under `test/oracle/corpus/*.bin`
//! is the natural corpus for the Syrup entrypoints (a spread is embedded
//! below; point a long fuzzing run at the whole directory). Cap'n Proto has no
//! checked-in byte corpus, so its seeds are encoder output built in the test.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const syrup = pancake.ocapn.codec.syrup;
const capnp = pancake.ocapn.codec.capnp;

/// Upper bound on one fuzz input. Large enough to cover every corpus frame and
/// deeply nested hostile constructions; small enough that the fuzzer spends
/// its budget on structure, not bulk.
const max_input = 4096;

/// `Smith.slice` replays a corpus entry by reading a little-endian u32 length
/// ahead of the slice bytes, so a seed is its frame prefixed with the frame's
/// length.
fn seed(comptime frame: []const u8) []const u8 {
    const entry: [4 + frame.len]u8 = comptime blk: {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(frame.len)), .little);
        break :blk len_buf ++ frame[0..frame.len].*;
    };
    return &entry;
}

/// Runtime sibling of `seed`, for seeds produced by an encoder in the test.
fn runtimeSeed(buf: []u8, frame_bytes: []const u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(frame_bytes.len), .little);
    @memcpy(buf[4..][0..frame_bytes.len], frame_bytes);
    return buf[0 .. 4 + frame_bytes.len];
}

/// Re-encoding a decoded message may refuse through the codec's typed refusals
/// (e.g. a decoded `near` deliver target never re-enters the wire — the
/// ADR-0010 perspective flip makes that pairing reachable from hostile bytes,
/// and `Unsupported*` names it). A refusal ends the property for this input;
/// only allocation failure is a real error.
fn swallowRefusal(err: anyerror) anyerror!void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
}

/// Round-trip totality from a successfully decoded message: its re-encoding
/// (when the codec admits it) must decode, and one further crossing must land
/// on the exact same bytes. The flip swaps `near`/`far` arms on each decode,
/// so `frame1` and `frame3` — two crossings apart — are the comparable pair.
fn expectReencodeStability(comptime codec: anytype, gpa: std.mem.Allocator, first: model.Message) anyerror!void {
    var frame1 = codec.encodeMessage(gpa, first) catch |err| return swallowRefusal(err);
    defer frame1.deinit();

    // Encoder output must always decode: totality of decode over encode.
    const second = try codec.decodeOwned(gpa, frame1.view());
    defer model.freeMessage(gpa, second);

    var frame2 = codec.encodeMessage(gpa, second) catch |err| return swallowRefusal(err);
    defer frame2.deinit();

    const third = try codec.decodeOwned(gpa, frame2.view());
    defer model.freeMessage(gpa, third);

    var frame3 = try codec.encodeMessage(gpa, third);
    defer frame3.deinit();

    try std.testing.expectEqualSlices(u8, frame1.bytes(), frame3.bytes());
}

fn syrupStreamingOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    // Two caps: the small one forces the cap-during-scan verdicts (ADR-0029)
    // onto structurally valid frames too; the large one lets them through to
    // the round trip. A `.decoded` verdict must never consume past either the
    // input or the cap.
    for ([_]usize{ 64, max_input }) |cap| {
        switch (syrup.decodePrefix(input, cap)) {
            .decoded => |decoded| {
                try std.testing.expect(decoded.consumed <= input.len);
                try std.testing.expect(decoded.consumed <= cap);
                const first = decoded.body.toOwned(gpa) catch |err| return swallowRefusal(err);
                defer model.freeMessage(gpa, first);
                try expectReencodeStability(syrup, gpa, first);
            },
            .incomplete, .malformed, .too_large => {},
        }
    }
}

/// Every seed's frame part must still decode, otherwise the corpus silently
/// stops seeding the success paths (the length prefix is `seed`'s replay
/// framing, not part of the frame).
fn ratifySyrupSeeds(seeds: []const []const u8) !void {
    for (seeds) |entry| {
        try std.testing.expect(syrup.decodePrefix(entry[4..], max_input) == .decoded);
    }
}

test "fuzz: syrup streaming decode and cap-on-parse are total over arbitrary bytes" {
    const seeds = [_][]const u8{
        seed(@embedFile("../oracle/corpus/op_deliver.bin")),
        seed(@embedFile("../oracle/corpus/op_abort.bin")),
        seed(@embedFile("../oracle/corpus/op_gc_exports.bin")),
        seed(@embedFile("../oracle/corpus/op_deliver_arg_set.bin")),
        seed(@embedFile("../oracle/corpus/op_handoff_receive.bin")),
        seed(@embedFile("../oracle/corpus/op_get.bin")),
    };
    try ratifySyrupSeeds(seeds[0..]);
    try std.testing.fuzz({}, syrupStreamingOne, .{ .corpus = seeds[0..] });
}

fn capnpOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var raw: [max_input]u8 = undefined;
    const input = raw[0..smith.slice(&raw)];
    const gpa = std.testing.allocator;

    // A Cap'n Proto frame is word storage: copy into an aligned buffer and
    // truncate to whole words, the shape the netlayer guarantees before the
    // codec ever sees the bytes.
    var words: [max_input]u8 align(8) = undefined;
    const word_len = input.len - (input.len % 8);
    @memcpy(words[0..word_len], input[0..word_len]);
    const frame = foundation.FrameView{ .bytes = words[0..word_len], .shape = .word };

    // `decodeBody` runs the eager traversal-budget charge pass over the raw
    // pointer graph; `toOwned` then exercises the lazy view walks and the
    // multi-allocation materializer.
    const body = capnp.decodeBody(frame) catch return;
    const first = body.toOwned(gpa) catch |err| return swallowRefusal(err);
    defer model.freeMessage(gpa, first);
    try expectReencodeStability(capnp, gpa, first);
}

test "fuzz: capnp decodeBody and owned projection are total over arbitrary word frames" {
    const gpa = std.testing.allocator;

    const args = [_]model.Argument{ .{ .bytes = "hello" }, .{ .integer = 7 } };
    var deliver_frame = try capnp.encodeMessage(gpa, .{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(0) } },
        .args = args[0..],
        .answer = .from(11),
    } });
    defer deliver_frame.deinit();
    var resolve_frame = try capnp.encodeMessage(gpa, .{ .resolve = .{
        .answer = .from(3),
        .resolution = .{ .fulfill = .{ .string = "done" } },
    } });
    defer resolve_frame.deinit();

    var buf0: [4 + 256]u8 = undefined;
    var buf1: [4 + 256]u8 = undefined;
    try std.testing.fuzz({}, capnpOne, .{ .corpus = &.{
        runtimeSeed(&buf0, deliver_frame.bytes()),
        runtimeSeed(&buf1, resolve_frame.bytes()),
    } });
}

fn syrupOwnedOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    // `decodeOwned` is the multi-allocation materializer: a mid-tree failure
    // must release every partial allocation, which `std.testing.allocator`
    // ratifies by failing the test on a leak.
    const first = syrup.decodeOwned(gpa, .{ .bytes = input, .shape = .byte }) catch |err| return swallowRefusal(err);
    defer model.freeMessage(gpa, first);
    try expectReencodeStability(syrup, gpa, first);
}

test "fuzz: syrup owned decode cleans up partial failures and round-trips successes" {
    const seeds = [_][]const u8{
        seed(@embedFile("../oracle/corpus/op_deliver.bin")),
        seed(@embedFile("../oracle/corpus/op_deliver_arg_big_integer.bin")),
        seed(@embedFile("../oracle/corpus/op_deliver_arg_tagged.bin")),
        seed(@embedFile("../oracle/corpus/op_handoff_give.bin")),
        seed(@embedFile("../oracle/corpus/op_start_session_v1_0.bin")),
        seed(@embedFile("../oracle/corpus/op_listen_promise_target.bin")),
    };
    try ratifySyrupSeeds(seeds[0..]);
    try std.testing.fuzz({}, syrupOwnedOne, .{ .corpus = seeds[0..] });
}
