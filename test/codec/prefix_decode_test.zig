//! Differential prefix-decode property test for the one-parser stream framer.
//!
//! The byte-stream netlayer frames an inbound stream by running the active
//! codec's decoder over the front of a read buffer (`decodePrefix`). The decoder
//! *is* the framer, so this is the untrusted-input attack surface; it must:
//!
//!   * report `.incomplete` for every strict prefix of a valid frame, and
//!     exactly `.decoded{ consumed = frame_len }` at the full length, never a
//!     partial apply, never an over-read;
//!   * find the boundary of the first frame in a concatenation and stop there;
//!   * reject structurally-invalid bytes as `.malformed` regardless of length;
//!   * reject a frame past `max_frame_bytes` as `.too_large`;
//!   * fail a pathologically deep nesting loud (bounded recursion), not crash.
//!
//! Driven entirely in-memory (no sockets): the same guarantee the connection
//! relies on, proven against the codec directly.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const syrup = pancake.ocapn.codec.syrup;
const capnp = pancake.ocapn.codec.capnp;
const dispatch = pancake.ocapn.codec.dispatch;

const big_max: usize = 1 << 20;

/// Every strict prefix of `bytes` is `.incomplete`; the full buffer is
/// `.decoded` consuming exactly `bytes.len`, with the same body discriminant as
/// the whole-frame decode. This is the core "split at every byte" property.
fn sweepSyrupExact(bytes: []const u8) !void {
    var k: usize = 0;
    while (k < bytes.len) : (k += 1) {
        const prefix = syrup.decodePrefix(bytes[0..k], big_max);
        std.testing.expect(prefix == .incomplete) catch |err| {
            std.debug.print("k={d}/{d} expected .incomplete, got {s}\n", .{ k, bytes.len, @tagName(prefix) });
            return err;
        };
    }

    const full = syrup.decodePrefix(bytes, big_max);
    try std.testing.expect(full == .decoded);
    try std.testing.expectEqual(bytes.len, full.decoded.consumed);

    const whole = try syrup.decodeBody(.{ .bytes = bytes, .shape = .byte });
    try std.testing.expectEqual(std.meta.activeTag(whole), std.meta.activeTag(full.decoded.body));
}

fn encodeSyrup(allocator: std.mem.Allocator, message: model.Message) !pancake.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, message);
}

fn encodeSyrupNext(allocator: std.mem.Allocator, message: model.Message) !pancake.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, message);
}

test "syrup decodePrefix: every byte split of a valid frame is incomplete until complete" {
    const allocator = std.testing.allocator;

    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const nested = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const deliver_args = [_]model.Argument{
        .{ .bytes = "hello" },
        .{ .symbol = "method" },
        .{ .list = nested[0..] },
        .{ .boolean = true },
    };

    var frames: std.ArrayList(pancake.foundation.Frame) = .empty;
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
    try frames.append(allocator, try encodeSyrupNext(allocator, .{
        .resolve = .{ .answer = .from(3), .resolution = .{ .fulfill = .{ .bytes = "ok" } } },
    }));
    try frames.append(allocator, try encodeSyrup(allocator, .{
        .gc_answer = .{ .positions = &.{ 11, 13 } },
    }));

    for (frames.items) |f| try sweepSyrupExact(f.bytes());
}

test "syrup decodePrefix: a concatenation yields the first frame and its exact length" {
    const allocator = std.testing.allocator;

    var first = try encodeSyrup(allocator, .{ .gc_answer = .{ .positions = &.{1} } });
    defer first.deinit();
    var second = try encodeSyrup(allocator, .{ .abort = .{ .kind = .other, .message = "bye" } });
    defer second.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, first.bytes());
    try buf.appendSlice(allocator, second.bytes());

    const p1 = syrup.decodePrefix(buf.items, big_max);
    try std.testing.expect(p1 == .decoded);
    try std.testing.expectEqual(first.bytes().len, p1.decoded.consumed);

    const rest = buf.items[p1.decoded.consumed..];
    const p2 = syrup.decodePrefix(rest, big_max);
    try std.testing.expect(p2 == .decoded);
    try std.testing.expectEqual(second.bytes().len, p2.decoded.consumed);
    try std.testing.expectEqual(rest.len, p2.decoded.consumed);
}

test "syrup decodePrefix: structurally invalid bytes are malformed, not incomplete" {
    const cases = [_][]const u8{
        "garbage", // does not open a record
        "<7'op:foo>", // unknown op symbol
        "<10'op:deliverX", // wrong byte where a reference record must start
        "<>", // empty record, no op symbol
        "<10'op:deliver<11'desc:export7+>[5:hello]42+f>trailing<", // trailing starts a new (incomplete) frame, but first frame is decoded
    };

    // The first four are malformed.
    inline for (cases[0..4]) |bytes| {
        try std.testing.expect(syrup.decodePrefix(bytes, big_max) == .malformed);
    }
    // The fifth decodes the first frame and reports its exact length (the
    // trailing bytes are the caller's next-frame problem, not an over-read).
    const concat = cases[4];
    const p = syrup.decodePrefix(concat, big_max);
    try std.testing.expect(p == .decoded);
    try std.testing.expect(p.decoded.consumed < concat.len);
}

test "syrup decodePrefix: a frame past max_frame_bytes is too_large" {
    const allocator = std.testing.allocator;
    var frame = try encodeSyrup(allocator, .{ .gc_answer = .{ .positions = &.{ 1, 2, 3, 4 } } });
    defer frame.deinit();

    // Exactly at the cap → decoded; one byte under → too_large (the decode
    // succeeds structurally, but consumed exceeds the cap).
    try std.testing.expect(syrup.decodePrefix(frame.bytes(), frame.bytes().len) == .decoded);
    try std.testing.expect(syrup.decodePrefix(frame.bytes(), frame.bytes().len - 1) == .too_large);
}

test "syrup decodePrefix: an incomplete prefix past max_frame_bytes is too_large, never incomplete" {
    const allocator = std.testing.allocator;
    var frame = try encodeSyrup(allocator, .{ .gc_answer = .{ .positions = &.{ 1, 2, 3, 4 } } });
    defer frame.deinit();

    // A still-arriving frame must be refused the moment its scanned length
    // crosses the cap (ADR-0029); it can never complete within the cap, and
    // an `incomplete` verdict there would let a streaming caller buffer past
    // the bound (the contract the netlayer spill's boundedness leans on,
    // ADR-0041). At a prefix of exactly the cap the scanner cannot yet know,
    // so `incomplete` is admissible there and the adapters keep the mirror
    // check; strictly past it the verdict must be `too_large`.
    const bytes = frame.bytes();
    const cap = bytes.len - 4;
    var k: usize = cap + 1;
    while (k < bytes.len) : (k += 1) {
        try std.testing.expect(syrup.decodePrefix(bytes[0..k], cap) == .too_large);
    }
}

test "capnp decodePrefix: an incomplete prefix declaring a body past max_frame_bytes is too_large" {
    const allocator = std.testing.allocator;
    var frame = try capnp.encodeMessage(allocator, .{ .gc_answer = .{ .positions = &.{ 7, 11, 13 } } });
    defer frame.deinit();

    // The single-segment header declares the whole frame's length, so the
    // refusal lands as soon as the header is readable, long before the body
    // arrives.
    const bytes = frame.bytes();
    const cap = bytes.len - 1;
    var k: usize = 8;
    while (k < bytes.len) : (k += 1) {
        try std.testing.expect(capnp.decodePrefix(bytes[0..k], cap) == .too_large);
    }
}

/// `<op:deliver>` to `<desc:export 0>` whose args are `depth`-deep empty lists,
/// hand-built so the test controls the exact nesting (the encoder bottoms out a
/// model tree; raw bytes are clearer here).
fn deepNestedDeliver(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<10'op:deliver<11'desc:export0+>");
    try buf.appendNTimes(allocator, '[', depth);
    try buf.appendNTimes(allocator, ']', depth);
    try buf.appendSlice(allocator, "ff>"); // answer: none, resolve-me: none
    return buf.toOwnedSlice(allocator);
}

test "syrup decodePrefix: deep nesting fails loud, never overflows the stack" {
    const allocator = std.testing.allocator;

    // Shallow enough to decode (well under the decode-recursion cap).
    const shallow = try deepNestedDeliver(allocator, 64);
    defer allocator.free(shallow);
    try std.testing.expect(syrup.decodePrefix(shallow, big_max) == .decoded);

    // Past the decode-recursion cap → malformed, not a crash.
    const deep = try deepNestedDeliver(allocator, 4096);
    defer allocator.free(deep);
    try std.testing.expect(syrup.decodePrefix(deep, big_max) == .malformed);
}

test "dispatch.decodePrefix routes syrup through the codec-neutral boundary" {
    const allocator = std.testing.allocator;
    var frame = try encodeSyrup(allocator, .{ .gc_answer = .{ .positions = &.{42} } });
    defer frame.deinit();

    const p = dispatch.decodePrefix(.syrup, frame.bytes(), big_max);
    try std.testing.expect(p == .decoded);
    try std.testing.expectEqual(frame.bytes().len, p.decoded.consumed);

    // A strict prefix is incomplete through the same boundary.
    try std.testing.expect(dispatch.decodePrefix(.syrup, frame.bytes()[0 .. frame.bytes().len - 1], big_max) == .incomplete);
}

test "capnp decodePrefix: word-aligned frame is incomplete until the segment table completes" {
    const allocator = std.testing.allocator;
    var frame = try capnp.encodeMessage(allocator, .{ .gc_answer = .{ .positions = &.{ 7, 11, 13 } } });
    defer frame.deinit();

    const bytes = frame.bytes();
    var k: usize = 0;
    while (k < bytes.len) : (k += 1) {
        try std.testing.expect(capnp.decodePrefix(bytes[0..k], big_max) == .incomplete);
    }

    const full = capnp.decodePrefix(bytes, big_max);
    try std.testing.expect(full == .decoded);
    try std.testing.expectEqual(bytes.len, full.decoded.consumed);

    // Cap below the frame length → too_large.
    try std.testing.expect(capnp.decodePrefix(bytes, bytes.len - 1) == .too_large);
}
