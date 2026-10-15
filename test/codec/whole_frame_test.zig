//! Whole-frame decode property test for both codecs.
//!
//! A codec decodes a frame the envelope or the transport has already
//! delimited (ADR-0110), so `decodeBody` has one answer for anything that is
//! not exactly one frame:
//!
//!   * every strict prefix of a valid frame is refused, `MalformedFrame` on
//!     Syrup and `Truncated` on Cap'n Proto, never a partial body, and the
//!     full length decodes.
//!   * a concatenation of two frames is `MalformedFrame`, never the first.
//!   * structurally invalid bytes are `MalformedFrame` regardless of length,
//!     and a well-formed record with an unknown op is `UnsupportedMessage`.
//!   * a pathologically deep nesting fails loud (bounded recursion), not crash.
//!
//! Driven entirely in-memory (no sockets): the same guarantee the session
//! relies on, proven against the codec directly.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;
const dispatch = glowcap.ocapn.codec.dispatch;

/// Every strict prefix of `bytes` is refused as malformed, and the full buffer
/// decodes. This is the core "split at every byte" property.
fn sweepSyrupExact(bytes: []const u8) !void {
    var k: usize = 0;
    while (k < bytes.len) : (k += 1) {
        try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(.{ .bytes = bytes[0..k], .shape = .byte }));
    }
    _ = try syrup.decodeBody(.{ .bytes = bytes, .shape = .byte });
}

fn encodeSyrup(allocator: std.mem.Allocator, message: model.Message) !glowcap.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, message);
}

test "syrup decodeBody: every strict prefix of a valid frame is malformed and the full frame decodes" {
    const allocator = std.testing.allocator;

    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const nested = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const deliver_args = [_]model.Argument{
        .{ .bytes = "hello" },
        .{ .symbol = "method" },
        .{ .list = nested[0..] },
        .{ .boolean = true },
        // A `D`-tagged binary64 whose eight raw payload bytes spell the record
        // and list delimiters. A framer that reads the payload instead of
        // stepping over it miscounts depth on exactly this input, so the sweep
        // has to carry one.
        .{ .float64 = @bitCast(@as(u64, 0x3E3C_5D5B_3E3C_5D5B)) },
    };

    var frames: std.ArrayList(glowcap.foundation.Frame) = .empty;
    defer {
        for (frames.items) |*f| f.deinit();
        frames.deinit(allocator);
    }

    try frames.append(allocator, try encodeSyrup(allocator, .{
        .abort = .{ .kind = .other, .message = "shutting down" },
    }));
    try frames.append(allocator, try encodeSyrup(allocator, .{ .deliver = .{
        .target = target,
        .args = deliver_args[0..],
        .answer = .from(42),
    } }));
    try frames.append(allocator, try encodeSyrup(allocator, .{ .deliver = .{
        .target = target,
        .args = &.{},
        .answer = null,
    } }));
    try frames.append(allocator, try encodeSyrup(allocator, .{
        .resolve = .{ .answer = .from(3), .resolution = .{ .fulfill = .{ .bytes = "ok" } } },
    }));
    try frames.append(allocator, try encodeSyrup(allocator, .{
        .gc_answer = .{ .positions = &.{ 11, 13 } },
    }));

    for (frames.items) |f| try sweepSyrupExact(f.bytes());
}

test "syrup decodeBody: a concatenation of two frames is malformed" {
    const allocator = std.testing.allocator;

    var first = try encodeSyrup(allocator, .{ .gc_answer = .{ .positions = &.{1} } });
    defer first.deinit();
    var second = try encodeSyrup(allocator, .{ .abort = .{ .kind = .other, .message = "bye" } });
    defer second.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, first.bytes());
    try buf.appendSlice(allocator, second.bytes());

    try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(.{ .bytes = buf.items, .shape = .byte }));
}

test "syrup decodeBody: structurally invalid bytes are malformed and an unknown op is unsupported" {
    try std.testing.expectError(error.UnsupportedMessage, syrup.decodeBody(.{ .bytes = "<7'op:foo>", .shape = .byte }));
    const cases = [_][]const u8{
        "garbage", // does not open a record
        "<10'op:deliverX", // wrong byte where a reference record must start
        "<>", // empty record, no op symbol
        "<10'op:deliver<11'desc:export7+>[5:hello]42+f>trailing<", // a complete frame followed by the start of another
    };

    inline for (cases) |bytes| {
        try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(.{ .bytes = bytes, .shape = .byte }));
    }
}

/// `<op:deliver>` to `<desc:export 0>` whose args are `depth`-deep empty lists,
/// hand-built so the test controls the exact nesting (the encoder bottoms out a
/// model tree. Raw bytes are clearer here).
fn deepNestedDeliver(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<10'op:deliver<11'desc:export0+>");
    try buf.appendNTimes(allocator, '[', depth);
    try buf.appendNTimes(allocator, ']', depth);
    try buf.appendSlice(allocator, "ff>"); // answer: none, resolve-me: none
    return buf.toOwnedSlice(allocator);
}

test "syrup decodeBody: deep nesting fails loud, never overflows the stack" {
    const allocator = std.testing.allocator;

    // Shallow enough to decode (well under the decode-recursion cap).
    const shallow = try deepNestedDeliver(allocator, 64);
    defer allocator.free(shallow);
    _ = try syrup.decodeBody(.{ .bytes = shallow, .shape = .byte });

    // Past the decode-recursion cap → malformed, not a crash.
    const deep = try deepNestedDeliver(allocator, 4096);
    defer allocator.free(deep);
    try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(.{ .bytes = deep, .shape = .byte }));
}

test "syrup decodeBody: an empty collection past the nesting limit is refused like a full one" {
    // The argument list is depth zero and each list inside it enters one
    // level, so `limit + 1` brackets is the deepest frame the decoder admits.
    // The innermost list is empty: no element walk runs inside it, so the
    // refusal has to fire on entry.
    const allocator = std.testing.allocator;
    const limit = syrup.decode.max_decode_nesting;
    const at_limit = try deepNestedDeliver(allocator, limit + 1);
    defer allocator.free(at_limit);
    _ = try syrup.decodeBody(.{ .bytes = at_limit, .shape = .byte });
    const past = try deepNestedDeliver(allocator, limit + 2);
    defer allocator.free(past);
    try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(.{ .bytes = past, .shape = .byte }));
}

test "syrup decodeBody: an empty argument list stays wire-backed" {
    // `decodeBody` lends no room, so every argument list it returns borrows
    // the wire, including one with no arguments.
    const frame = "<10'op:deliver<11'desc:export0+>[]ff>";
    const body = try syrup.decodeBody(.{ .bytes = frame, .shape = .byte });
    try std.testing.expect(body.deliver.args.backingViews() == null);
    try std.testing.expectEqual(@as(usize, 0), try body.deliver.args.len());
}

test "dispatch.decodeBody routes syrup through the codec-neutral boundary" {
    const allocator = std.testing.allocator;
    var frame = try encodeSyrup(allocator, .{ .gc_answer = .{ .positions = &.{42} } });
    defer frame.deinit();

    _ = try dispatch.decodeBody(.syrup, frame.view());

    // A strict prefix is malformed through the same boundary.
    try std.testing.expectError(error.MalformedFrame, dispatch.decodeBody(.syrup, .{ .bytes = frame.bytes()[0 .. frame.bytes().len - 1], .shape = .byte }));
}

test "capnp decodeBody: every strict word prefix is truncated and the full frame decodes" {
    const allocator = std.testing.allocator;
    var frame = try capnp.encodeMessage(allocator, .{ .gc_answer = .{ .positions = &.{ 7, 11, 13 } } });
    defer frame.deinit();

    const bytes = frame.bytes();
    var k: usize = 0;
    while (k < bytes.len) : (k += 8) {
        try std.testing.expectError(error.Truncated, capnp.decodeBody(.{ .bytes = bytes[0..k], .shape = .word }));
    }

    _ = try capnp.decodeBody(frame.view());
}
