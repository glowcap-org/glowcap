//! Codec-neutral view projection: every message arm projects, and deliver,
//! resolve, and start_session round-trip through the borrowed body.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");
const handoff_fixtures = @import("../../support/handoff_fixtures.zig");

const harness = @import("harness.zig");
const expectFixtureBytes = harness.expectFixtureBytes;
const repeatedByte = harness.repeatedByte;
const hexToOwned = harness.hexToOwned;

// ── Codec-neutral view projection round-trips ────────────────────────────────
//
// Encode → `decodeBody` (neutral view) → `toOwned` → re-encode, asserting the
// bytes survive the round trip. This is the strongest fidelity check: any arm
// the projection drops or mis-shapes diverges on re-encode.

fn expectBodyByteRoundTrip(profile: model.CaptpVersion, message: model.Message) !void {
    const allocator = std.testing.allocator;
    // The codec flips reference perspective on every wire crossing (ADR-0010),
    // so a single encode→decode→encode is NOT byte-stable: a payload `Near`
    // becomes `<desc:import-object>` becomes a decoded `Far`, which re-encodes as
    // `<desc:export>`. Two crossings restore the original perspective (the flip
    // is an involution), so the bytes after the second crossing equal the first
    // encoding, any arm `decodeBody`/`toOwned` drops or mangles diverges.
    //
    // Deliver/get/index/listen targets must therefore be promise-shaped here: a
    // `Far` target decodes to a `Near` target, which the target encoder rejects
    // by design (a `Near` target is a runtime-bug signal, never sent on the
    // wire). Far-receiver *decoding* is covered by the oracle-fixture tests.
    var frame0 = try syrup.encodeMessageForProfile(allocator, profile, message);
    defer frame0.deinit();

    const owned1 = try (try syrup.decodeBodyForProfile(profile, frame0.view())).toOwned(allocator);
    defer model.freeMessage(allocator, owned1);
    var frame1 = try syrup.encodeMessageForProfile(allocator, profile, owned1);
    defer frame1.deinit();

    const owned2 = try (try syrup.decodeBodyForProfile(profile, frame1.view())).toOwned(allocator);
    defer model.freeMessage(allocator, owned2);
    var frame2 = try syrup.encodeMessageForProfile(allocator, profile, owned2);
    defer frame2.deinit();

    try std.testing.expectEqualSlices(u8, frame0.bytes(), frame2.bytes());
}

test "neutral view projects every Syrup-encodable argument arm" {
    const nested = [_]model.Argument{ .{ .integer = -3 }, .{ .boolean = false }, .{ .void = {} } };
    const args = [_]model.Argument{
        .{ .bytes = "raw" },
        .{ .symbol = "sym" },
        .{ .string = "str" },
        .{ .integer = 9 },
        .{ .integer = -9 },
        .{ .boolean = true },
        .{ .void = {} },
        .{ .reference = .{ .near = model.NearRef.object(1) } },
        .{ .reference = .{ .far = model.FarRef.object(2) } },
        .{ .list = nested[0..] },
        .{ .set = nested[0..] },
        .{ .tagged = .{ .tag = "rec", .value = nested[0..] } },
        .{ .keyword = "kw" },
    };
    // Promise target: a `Far` target would decode to an un-re-encodable `Near`
    // target (see `expectBodyByteRoundTrip`). Object-kind refs only: the far/
    // import promise-kind is intentionally not on the wire (`Far`→`<desc:export>`
    // drops it), covered separately by the desc:import-promise kind test above.
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .args = args[0..],
        .answer = .from(42),
    } });
}

test "neutral view round-trips deliver with promise target and resolver-callback" {
    const args = [_]model.Argument{ .{ .symbol = "fulfill" }, .{ .reference = .{ .near = model.NearRef.object(3) } } };
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{
        .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(5) } },
            .args = args[0..],
            .answer = .from(8),
            // Object-kind resolver desc: the promise-kind on a decoded `Far` import
            // is not wire-preserved (`Far`→`<desc:export>`), so it would not survive
            // the second crossing, kind preservation is tested via near→far above.
            .resolve_me_desc = .{ .near = model.NearRef.object(4) },
        },
    });
}

test "neutral view round-trips resolve, gc, abort, listen, get, index" {
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(2) } } },
    } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .@"break" = .{ .message = "boom" } },
    } });
    const positions = [_]u64{ 5, 6, 7 };
    const deltas = [_]u64{ 1, 1, 2 };
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .gc_export = .{ .positions = positions[0..], .deltas = deltas[0..] } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .gc_answer = .{ .positions = positions[0..] } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .abort = .{ .kind = .protocol_error, .message = "bye" } });
    // Promise targets/receivers: a `Far` target decodes to an un-re-encodable
    // `Near` target (see `expectBodyByteRoundTrip`). Far-receiver decoding for
    // listen/get/index is covered by the oracle-fixture tests.
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .listener = .{ .near = model.NearRef.object(9) },
        .mode = .shortening_or_settling,
    } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .get = .{ .receiver = .{ .promise = .{ .answer_position = .from(2) } }, .field = "name", .answer = .from(3) } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .index = .{ .receiver = .{ .promise = .{ .answer_position = .from(2) } }, .index = .{ .integer = 5 }, .answer = .from(4) } });
}

test "neutral view round-trips start_session" {
    const pubkey = repeatedByte(32, 0xaa);
    const sig = repeatedByte(64, 0xcc);
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = pubkey[0..] },
        .acceptable_location = .{ .transport = "memory", .designator = "exporter" },
        .acceptable_location_sig = .{ .bytes = sig[0..] },
    } });
}
