//! Codec neutrality, proven per message arm.
//!
//! pancake's whole reason to exist is that the session state machine is
//! codec-neutral: a `Deliver` means the same thing whether Syrup or Cap'n Proto
//! carried it. The scenario traces in `test/oracle/scenario_trace_test.zig` show
//! that for two whole conversations; this proves it for each message arm in the
//! shared passable set, the arms both codecs carry the same way: deliver,
//! resolve, gc-export, gc-answer, abort, listen, get, index, and untag.
//!
//! Two message arms are proven elsewhere because their cross-codec contract is
//! not a flat `messagesEqual`. `start_session` carries the codec negotiation
//! itself and is round-tripped per codec in `syrup_test.zig` and
//! `capnp_test.zig`. The `handoff` give and receive arms carry a signature whose
//! signing domain is the decoded record's Syrup canonicalization, so their
//! cross-codec contract is the re-encode-and-reverify test in
//! `test/engine/cross_peer_test.zig`.
//!
//! For each message, we encode it through Syrup and through Cap'n Proto, decode
//! each back to the codec-neutral model (the production `decodeBody` path,
//! complete for every argument kind), and assert the two decoded models are
//! structurally equal. Both codecs apply the same wire-perspective flip on decode
//! (ADR-0010), so a faithful codec lands on the same model — a single
//! `messagesEqual` per message witnesses that Syrup and Cap'n Proto are
//! interchangeable for it.
//!
//! The corpus is the *shared* passable set — what both codecs carry the same way,
//! including an `error` argument (Syrup encodes it via `writeError`, Cap'n Proto
//! via its error arm). A few shapes are deliberately codec-dialect-specific and
//! excluded: a `handoff` *argument* (Cap'n Proto carries it inline; Syrup carries
//! handoffs through their own signed-envelope flow), a `sturdy` *deliver target*
//! (you enliven a sturdyref, you don't deliver to one), and the promise/object
//! *kind* of a `far` reference — OCapN's `desc:export` is kind-less by design (the
//! receiver resolves the kind from its own export table), so Syrup drops it on the
//! wire while Cap'n Proto carries it. Each is covered by its own per-codec
//! round-trip test, not this shared-set equivalence.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;

const profile = model.WireProfile.pre_spec;

/// Encode `message` through `codec_id` and decode it back to the owned,
/// codec-neutral model. Caller owns the result (`model.freeMessage`).
fn decodedVia(allocator: std.mem.Allocator, codec_id: model.CodecId, message: model.Message) !model.Message {
    var wire = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, profile, message);
    defer wire.deinit();
    const body = try codec.dispatch.decodeBody(codec_id, wire.view());
    return body.toOwned(allocator);
}

/// A message means the same thing through either codec.
fn expectCodecEquivalent(message: model.Message) !void {
    const allocator = std.testing.allocator;
    const via_syrup = try decodedVia(allocator, .syrup, message);
    defer model.freeMessage(allocator, via_syrup);
    const via_capnp = try decodedVia(allocator, .capnp, message);
    defer model.freeMessage(allocator, via_capnp);
    try std.testing.expect(messagesEqual(via_syrup, via_capnp));
}

test "deliver arms are codec-equivalent across every target and argument kind" {
    const call_args = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };

    // The shared passable breadth in one deliver, plus three target shapes,
    // including an `error` argument, which both codecs carry (Syrup encodes it
    // via `writeError`, Cap'n Proto via its error arm). Only the handoff argument
    // arm is codec-specific; it is covered by the handoff message tests.
    try expectCodecEquivalent(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &.{
            .{ .integer = -99 },
            .{ .big_integer = .{
                .negative = true,
                .digits = "340282366920938463463374607431768211456",
            } },
            .{ .float64 = 1.5 },
            .{ .boolean = true },
            .{ .bytes = &.{ 1, 2, 3 } },
            .{ .string = "hello" },
            .{ .symbol = "run" },
            .{ .keyword = "color" },
            .{ .void = {} },
            .{ .reference = .{ .far = model.FarRef.object(2) } },
            .{ .list = &call_args },
            .{ .set = &.{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } } },
            .{ .tagged = .{ .tag = "point", .value = &call_args } },
            .{ .@"error" = .{ .message = "boom" } },
            .{ .@"struct" = &.{
                .{ .key = "name", .value = .{ .string = "tabby" } },
                .{ .key = "age", .value = .{ .integer = 12 } },
                .{ .key = "nested", .value = .{ .@"struct" = &.{
                    .{ .key = "x", .value = .{ .integer = 1 } },
                } } },
            } },
        },
        .answer = .from(7),
    } });

    try expectCodecEquivalent(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(3) }, .args = &.{} } });
    try expectCodecEquivalent(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(1), .path = .{ .ops = &.{} } } },
        .args = &.{},
    } });
}

test "resolve / gc / abort / listen / get / index arms are codec-equivalent" {
    try expectCodecEquivalent(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{ .integer = -7 } } } });
    try expectCodecEquivalent(.{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } },
    } });
    try expectCodecEquivalent(.{ .resolve = .{ .answer = .from(9), .resolution = .{ .@"break" = .{ .message = "boom" } } } });

    try expectCodecEquivalent(.{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } });
    try expectCodecEquivalent(.{ .gc_answer = .{ .positions = &.{ 1, 4, 9 } } });
    try expectCodecEquivalent(.{ .gc_answer = .{ .positions = &.{} } });

    try expectCodecEquivalent(.{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } });
    try expectCodecEquivalent(.{ .abort = .{ .kind = .normal_shutdown, .message = "" } });

    try expectCodecEquivalent(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(7), .path = .{ .ops = &.{} } } },
        .listener = .{ .near = model.NearRef.object(2) },
        .wants_partial = false,
    } });

    try expectCodecEquivalent(.{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } });
    try expectCodecEquivalent(.{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = -3, .answer = .from(9) } });
    try expectCodecEquivalent(.{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } });
}

/// Encode a well-formed two-key struct through `codec_id`, patch the second
/// key's bytes to repeat the first — the duplicate-key frame a hostile peer
/// would send — and assert the codec refuses it on the live decode path
/// (`decodeBody` + `toOwned`), per ADR-0046's key rule. Syrup refuses while
/// slicing the dict during body projection; Cap'n Proto refuses when the lazy
/// struct backing is built. Either way the refusal is typed and lands before
/// an owned message exists.
fn expectDuplicateKeyStructRefused(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;
    const entries = [_]model.StructEntry{
        .{ .key = "k1", .value = .{ .integer = 1 } },
        .{ .key = "k2", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var wire_frame = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, profile, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &args,
        .answer = .from(7),
        .resolve_me_desc = null,
    } });
    defer wire_frame.deinit();

    const buf = try allocator.dupe(u8, wire_frame.bytes());
    defer allocator.free(buf);
    const second_key = std.mem.indexOf(u8, buf, "k2") orelse return error.TestUnexpectedResult;
    @memcpy(buf[second_key .. second_key + 2], "k1");
    const view = pancake.foundation.FrameView{ .bytes = buf, .shape = wire_frame.view().shape };

    const refused = blk: {
        const body = codec.dispatch.decodeBody(codec_id, view) catch break :blk true;
        const owned = body.toOwned(allocator) catch break :blk true;
        model.freeMessage(allocator, owned);
        break :blk false;
    };
    try std.testing.expect(refused);
}

test "a duplicate-key Struct is refused identically through either codec" {
    try expectDuplicateKeyStructRefused(.syrup);
    try expectDuplicateKeyStructRefused(.capnp);
}

test "i64 boundary integers round-trip and stay codec-equivalent (regression: minInt magnitude is 2^63)" {
    // minInt(i64) is written by Syrup as the unsigned magnitude 9223372036854775808
    // (2^63) plus a `-` sign; parsing that magnitude as i64 overflowed, so Syrup
    // used to reject a frame it had just encoded. Both codecs must now carry the
    // full i64 range and agree on it.
    try expectCodecEquivalent(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{
            .{ .integer = std.math.minInt(i64) },
            .{ .integer = std.math.maxInt(i64) },
            .{ .integer = std.math.minInt(i64) + 1 },
            .{ .integer = -1 },
            .{ .integer = 0 },
        },
    } });
}
