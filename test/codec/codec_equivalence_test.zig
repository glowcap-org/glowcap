//! Codec neutrality, proven per message arm.
//!
//! glowcap's whole reason to exist is that the session state machine is
//! codec-neutral: a `Deliver` means the same thing whether Syrup or Cap'n Proto
//! carried it. The scenario traces in `test/oracle/scenario_trace_test.zig` show
//! that for two whole conversations. This proves it for each message arm in the
//! shared passable set, the arms both codecs carry the same way: deliver,
//! resolve, gc-export, gc-answer, abort, listen, get, index, and untag.
//!
//! Two message arms are proven elsewhere because their cross-codec contract is
//! not a flat `messagesEqual`. `start_session` carries the codec negotiation
//! itself and is round-tripped per codec in `test/codec/syrup/` and
//! `capnp_test.zig`. The `handoff` give and receive arms carry a signature whose
//! signing domain is the decoded record's Syrup canonicalization, so their
//! cross-codec contract is the re-encode-and-reverify test in
//! `test/engine/cross_peer/`.
//!
//! For each message, we encode it through Syrup and through Cap'n Proto, decode
//! each back to the codec-neutral model (the production profile-aware decode path,
//! complete for every argument kind), and assert the two decoded models are
//! structurally equal. Both codecs apply the same wire-perspective flip on decode
//! (ADR-0010), so a faithful codec lands on the same model, a single
//! `messagesEqual` per message witnesses that Syrup and Cap'n Proto are
//! interchangeable for it.
//!
//! The corpus is the *shared* passable set, what both codecs carry the same way,
//! including an `error` argument (Syrup encodes it via `writeError`, Cap'n Proto
//! via its error arm). A few shapes are codec-dialect-specific and
//! excluded: a `handoff` *argument* (Cap'n Proto carries it inline. Syrup carries
//! handoffs through their own signed-envelope flow), a `sturdy` *deliver target*
//! (you enliven a sturdyref, you don't deliver to one), and the promise/object
//! *kind* of a `far` reference. OCapN's `desc:export` is kind-less by design (the
//! receiver resolves the kind from its own export table), so Syrup drops it on the
//! wire while Cap'n Proto carries it. Each is covered by its own per-codec
//! round-trip test, not this shared-set equivalence.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;

const default_profile = model.CaptpVersion.next;

/// Encode `message` through `codec_id` and decode it back to the owned,
/// codec-neutral model. Caller owns the result (`model.freeMessage`).
fn decodedVia(allocator: std.mem.Allocator, codec_id: model.CodecId, profile: model.CaptpVersion, message: model.Message) !model.Message {
    var wire = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, profile, message);
    defer wire.deinit();
    const body = try codec.dispatch.decodeBodyForProfile(codec_id, profile, wire.view());
    return body.toOwned(allocator);
}

/// A message means the same thing through either codec.
fn expectCodecEquivalent(message: model.Message) !void {
    try expectCodecEquivalentForProfile(.v1_0, message);
    switch (message) {
        .get, .index, .untag, .resolve => return,
        else => {},
    }
    try expectCodecEquivalentForProfile(.next, message);
}

fn expectCodecEquivalentForProfile(profile: model.CaptpVersion, message: model.Message) !void {
    const allocator = std.testing.allocator;
    var wire = message;
    if (profile == .next and wire == .deliver and wire.deliver.answer != null and wire.deliver.resolve_me_desc == null)
        wire.deliver.resolve_me_desc = .{ .near = model.NearRef.object(71) };
    const via_syrup = try decodedVia(allocator, .syrup, profile, wire);
    defer model.freeMessage(allocator, via_syrup);
    const via_capnp = try decodedVia(allocator, .capnp, profile, wire);
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
        .target = .{ .promise = .{ .answer_position = .from(1) } },
        .args = &.{},
    } });
}

test "a sturdyref argument is codec-equivalent (the sturdy dialect boundary is the target, not the payload)" {
    // A sturdyref in *argument* position is a passable OCapN value both codecs
    // carry: Cap'n Proto encodes it inline, and Syrup renders it as
    // `<ocapn-sturdyref <ocapn-peer …> swissnum>`, the exact record the decoder
    // reads back. Only a sturdy *deliver target* is codec-dialect-specific.
    try expectCodecEquivalent(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &.{
            .{ .reference = .{ .sturdy = &.{
                .peer = .{ .transport = "tcp", .designator = "host:9000" },
                .swissnum = &.{ 0xde, 0xad, 0xbe, 0xef },
            } } },
        },
        .answer = .from(7),
    } });
}

test "a sturdyref argument with locator hint entries is codec-equivalent" {
    const entries = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
    };
    try expectCodecEquivalent(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &.{
            .{ .reference = .{ .sturdy = &.{
                .peer = .{
                    .transport = "tcp",
                    .designator = "host:9000",
                    .hints = .{ .entries = &entries },
                },
                .swissnum = &.{ 0xde, 0xad, 0xbe, 0xef },
            } } },
        },
        .answer = .from(7),
    } });
}

test "route-bearing sturdyrefs and hellos are codec-equivalent" {
    const fallback_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = "ocapn://127.0.0.1%3A9001.tcp" },
    }};
    const via_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = "ocapn://peer-key.iroh" },
    }};
    try expectCodecEquivalent(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &.{
            .{ .reference = .{ .sturdy = &.{
                .peer = .{
                    .transport = model.transport.tcp,
                    .designator = "127.0.0.1:9000",
                    .hints = .{ .entries = &fallback_hints },
                },
                .swissnum = "fallback",
            } } },
            .{ .reference = .{ .sturdy = &.{
                .peer = .{
                    .transport = model.transport.id,
                    .designator = "peer-key",
                    .hints = .{ .entries = &via_hints },
                },
                .swissnum = "identity",
            } } },
        },
        .answer = .from(7),
    } });

    const pubkey = @as([32]u8, @splat(0xaa));
    const signature = @as([64]u8, @splat(0xbb));
    try expectCodecEquivalent(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &pubkey },
        .acceptable_location = .{
            .transport = model.transport.id,
            .designator = "peer-key",
            .hints = .{ .entries = &via_hints },
        },
        .acceptable_location_sig = .{ .bytes = &signature },
    } });
}

test "resolve / gc / abort / listen / get / index arms are codec-equivalent" {
    try expectCodecEquivalentForProfile(.v1_0, .{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{ .integer = -7 } } } });
    try expectCodecEquivalentForProfile(.v1_0, .{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } },
    } });
    try expectCodecEquivalentForProfile(.v1_0, .{ .resolve = .{ .answer = .from(9), .resolution = .{ .@"break" = .{ .message = "boom" } } } });

    try expectCodecEquivalent(.{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } });
    try expectCodecEquivalent(.{ .gc_answer = .{ .positions = &.{ 1, 4, 9 } } });
    try expectCodecEquivalent(.{ .gc_answer = .{ .positions = &.{} } });

    try expectCodecEquivalent(.{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } });
    try expectCodecEquivalent(.{ .abort = .{ .kind = .normal_shutdown, .message = "" } });

    try expectCodecEquivalent(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .settling_only,
    } });

    try expectCodecEquivalent(.{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } });
    try expectCodecEquivalent(.{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = .{ .integer = -3 }, .answer = .from(9) } });
    try expectCodecEquivalent(.{ .index = .{
        .receiver = .{ .far = model.FarRef.object(6) },
        .index = .{ .big_integer = .{ .negative = true, .digits = "9223372036854775809" } },
        .answer = .from(10),
    } });
    try expectCodecEquivalent(.{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } });
}

/// Encode a well-formed two-key struct through `codec_id`, patch the second
/// key's bytes to repeat the first, the duplicate-key frame an untrusted peer
/// would send, and assert the codec refuses it on the live decode path
/// (`decodeBody` + `toOwned`), per ADR-0046's key rule. Syrup refuses while
/// slicing the dict during body projection. Cap'n Proto refuses when the lazy
/// struct backing is built. Either way the refusal is typed and lands before
/// an owned message exists.
fn expectDuplicateKeyStructRefused(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;
    const entries = [_]model.StructEntry{
        .{ .key = "k1", .value = .{ .integer = 1 } },
        .{ .key = "k2", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var wire_frame = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, default_profile, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &args,
        .answer = .from(7),
        .resolve_me_desc = .{ .near = model.NearRef.object(71) },
    } });
    defer wire_frame.deinit();

    const buf = try allocator.dupe(u8, wire_frame.bytes());
    defer allocator.free(buf);
    const second_key = std.mem.indexOf(u8, buf, "k2") orelse return error.TestUnexpectedResult;
    @memcpy(buf[second_key .. second_key + 2], "k1");
    const view = glowcap.foundation.FrameView{ .bytes = buf, .shape = wire_frame.view().shape };

    const refused = blk: {
        const body = codec.dispatch.decodeBodyForProfile(codec_id, default_profile, view) catch break :blk true;
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
    // (2^63) plus a `-` sign. Parsing that magnitude as i64 overflows, so the
    // decoder must not reject a frame it just encoded. Both codecs carry the
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

test "next delivery forms preserve inline subscription semantics through both codecs" {
    const allocator = std.testing.allocator;
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        inline for (.{ model.ListenMode.shortening_only, model.ListenMode.shortening_or_settling }) |mode| {
            inline for (.{ @as(?model.AnswerPosition, null), @as(?model.AnswerPosition, .from(42)) }) |answer| {
                const message = model.Message{ .deliver = .{
                    .target = .{ .far = model.FarRef.object(7) },
                    .args = &.{},
                    .answer = answer,
                    .resolve_me_desc = .{ .near = model.NearRef.promise(9) },
                    .listen_mode = mode,
                } };
                const decoded = try decodedVia(allocator, codec_id, .next, message);
                defer model.freeMessage(allocator, decoded);
                try std.testing.expectEqual(answer, decoded.deliver.answer);
                try std.testing.expectEqual(mode, decoded.deliver.listen_mode);
                try std.testing.expectEqual(model.Reference{ .far = model.FarRef.promise(9) }, decoded.deliver.resolve_me_desc.?);
            }
        }
        const only = try decodedVia(allocator, codec_id, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{},
        } });
        defer model.freeMessage(allocator, only);
        try std.testing.expect(only.deliver.answer == null and only.deliver.resolve_me_desc == null);
        const invalid = [_]model.Message{
            .{ .deliver = .{ .target = .{ .far = model.FarRef.object(7) }, .args = &.{}, .answer = .from(1) } },
            .{ .deliver = .{ .target = .{ .far = model.FarRef.object(7) }, .args = &.{}, .resolve_me_desc = .{ .near = model.NearRef.object(9) }, .listen_mode = .settling_only } },
            .{ .deliver = .{ .target = .{ .far = model.FarRef.object(7) }, .args = &.{}, .resolve_me_desc = .{ .far = model.FarRef.object(9) } } },
        };
        for (invalid) |message| try std.testing.expectError(error.UnsupportedMessage, codec.dispatch.encodeMessageForProfile(codec_id, allocator, .next, message));
    }
    const invalid_syrup = [_][]const u8{
        "<10'op:deliver<11'desc:export7+>[]1+>",
        "<10'op:deliver<11'desc:export7+>[]ff>",
        "<10'op:deliver<11'desc:export7+>[]f<11'desc:export9+>3+>",
        "<10'op:deliver<11'desc:export7+>[]f<18'desc:import-object9+>2+>",
        "<15'op:deliver-only<11'desc:export7+>[]f>",
    };
    for (invalid_syrup) |bytes| try std.testing.expectError(error.MalformedFrame, codec.syrup.decodeBodyForProfile(.next, .{ .bytes = bytes, .shape = .byte }));
}

test "next Cap'n Proto rejects absent malformed and unnegotiated inline mode bits" {
    const allocator = std.testing.allocator;
    const capnp = codec.capnp;
    const shared = capnp.shared;
    var frame = try capnp.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
        .resolve_me_desc = .{ .near = model.NearRef.object(9) },
    } });
    defer frame.deinit();
    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    const parsed = try capnp.decodeMessageView(view);
    const flags = bytes[(parsed.body.data_idx + 1) * capnp.wire.word_bytes ..][0..capnp.wire.word_bytes];
    const valid = std.mem.readInt(u64, flags, .little);
    const invalid = [_]shared.DeliverFlags{
        .{ .has_answer = true, .has_resolve_me = true },
        .{ .has_answer = true, .has_resolve_me = true, .listen_mode = 2 },
        .{ .has_answer = true },
        .{ .listen_mode = 1 },
        .{ .has_answer = true, .has_resolve_me = true, .listen_mode = 3, .reserved = 1 << 4 },
    };
    for (invalid) |value| {
        std.mem.writeInt(u64, flags, @bitCast(value), .little);
        try std.testing.expectError(error.MalformedFrame, capnp.decodeBodyForProfile(.next, view));
    }
    std.mem.writeInt(u64, flags, valid, .little);
    try std.testing.expectEqual(model.ListenMode.shortening_or_settling, (try capnp.decodeBodyForProfile(.next, view)).deliver.listen_mode);
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBodyForProfile(.v1_0, view));
}
