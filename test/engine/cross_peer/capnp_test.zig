//! Handoff gives over a Cap'n Proto session: typed fields rather than raw
//! signed bytes, and both hint shapes round-tripping.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const crypto = glowcap.foundation.crypto;
const syrup = glowcap.ocapn.codec.syrup;
const cross_peer = @import("../../support/cross_peer.zig");
const CountingAllocator = @import("../../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../../support/peer_fixture.zig");

const fixtures = @import("fixtures.zig");
const repeated = fixtures.repeated;
const recipient_key = fixtures.recipient_key;
const gifter_session = fixtures.gifter_session;
const gifter_side = fixtures.gifter_side;
const receiving_session = fixtures.receiving_session;
const receiving_side = fixtures.receiving_side;
const give_signature = fixtures.give_signature;
const receive_signature = fixtures.receive_signature;
const gift_id_a = fixtures.gift_id_a;
const gift_id_b = fixtures.gift_id_b;
const sideOf = fixtures.sideOf;
const GifterSessionFixture = fixtures.GifterSessionFixture;
const PermissiveGifterSessionFixture = fixtures.PermissiveGifterSessionFixture;
const giveWith = fixtures.giveWith;
const receiveWith = fixtures.receiveWith;
const RejectingVerifier = fixtures.RejectingVerifier;
const RoutingVerifier = fixtures.RoutingVerifier;
const signedGive = fixtures.signedGive;

test "a binding-originated give carries typed fields over a Cap'n Proto session, not just Syrup's raw_signed" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedWithCodec(allocator, .capnp);
    defer pair.deinit();

    // The exact shape a binding hands `Peer.sendResolveHandoffGive`:
    // `handoff_gifter.buildSignedGive` (what `glowcap_build_handoff_give`
    // calls) returns a Syrup-encoded `<desc:sig-envelope …>`. Before this, the
    // send path only ever set that envelope as `raw_signed` and left the typed
    // fields empty, so a Cap'n Proto session (which does not understand
    // `raw_signed`) shipped an empty give.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    // `pairedWithCodec` is the unsigned fixture path: both
    // handshake halves carry the zero session key. The give still has to name
    // that actual recipient session rather than an unrelated synthetic key.
    const recipient_pub_key = repeated(32, 0);
    try expectCapnpGiveRoundTrip(allocator, &pair, gifter_secret, recipient_pub_key[0..], .{
        .transport = "tcp",
        .designator = "127.0.0.1:9200",
        .hints = model.Hints.emptyMap(),
    });
}

test "a Cap'n Proto session round-trips a handoff give with #f exporter hints" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedWithCodec(allocator, .capnp);
    defer pair.deinit();
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x61));
    const recipient_pub_key = repeated(32, 0);
    try expectCapnpGiveRoundTrip(allocator, &pair, gifter_secret, recipient_pub_key[0..], .{
        .transport = "tcp",
        .designator = "127.0.0.1:9201",
        .hints = model.Hints.emptyFalse(),
    });
}

test "a Cap'n Proto session round-trips a handoff give with direct-addresses hints" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedWithCodec(allocator, .capnp);
    defer pair.deinit();
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x71));
    const recipient_pub_key = repeated(32, 0);
    var entry_buf: [1]model.HintEntry = undefined;
    const hints = model.Hints.forDirectAddresses("127.0.0.1:9202", &entry_buf);
    try expectCapnpGiveRoundTrip(allocator, &pair, gifter_secret, recipient_pub_key[0..], .{
        .transport = "keyed-tcp",
        .designator = &@as([64]u8, @splat('a')),
        .hints = hints,
    });
}

fn expectCapnpGiveRoundTrip(
    allocator: std.mem.Allocator,
    pair: *engine.pairing.Pair,
    gifter_secret: crypto.SecretKey,
    recipient_pub_key: []const u8,
    peer: model.PeerLocator,
) !void {
    const exporter_location = try engine.encodePeerLocatorRecord(allocator, peer);
    defer allocator.free(exporter_location);
    const give_bytes = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_pub_key,
        exporter_location,
        gifter_session[0..],
        gifter_side[0..],
        gift_id_a[0..],
    );
    defer allocator.free(give_bytes);

    try pair.p1.exportObject(9);
    try pair.p2.importObject(9);
    try pair.p2.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(9) },
        .args = &.{},
        .answer = model.AnswerPosition.from(5),
    } });
    try cross_peer.pumpOne(&pair.p2, &pair.p1);
    {
        var ask = pair.p1.pollEvent() orelse return error.ExpectedDeliverEvent;
        defer ask.deinit();
    }

    try pair.p1.sendResolveHandoffGive(
        pair.p1.session_state.answerTargetNamed(.fromWire(.from(5))).?,
        give_bytes,
    );
    try cross_peer.pumpAll(&pair.p1, &pair.p2);

    var event = pair.p2.pollEvent() orelse return error.ExpectedResolveEvent;
    defer event.deinit();
    const view = try event.view();
    const arg = switch (view.resolve.resolution) {
        .fulfill => |a| a,
        .@"break" => return error.ExpectedFulfill,
    };
    const give_view = switch (arg) {
        .handoff => |h| switch (h) {
            .give => |g| g,
            .receive => return error.ExpectedGive,
        },
        else => return error.ExpectedHandoffArgument,
    };

    const owned_give = try give_view.toOwned(allocator);
    defer model.freeHandoffGive(allocator, owned_give);
    try std.testing.expectEqualSlices(u8, recipient_pub_key, owned_give.recipient_key);
    try std.testing.expectEqualStrings(peer.transport, owned_give.exporter.transport);
    try std.testing.expectEqualStrings(peer.designator, owned_give.exporter.designator);
    try std.testing.expectEqual(peer.hints.wire_form, owned_give.exporter.hints.wire_form);
    try std.testing.expectEqual(peer.hints.entries.len, owned_give.exporter.hints.entries.len);

    const uri = try engine.handoff_recipient.exporterLocatorUri(allocator, give_view.exporter);
    defer allocator.free(uri);
    try std.testing.expect(std.mem.startsWith(u8, uri, "ocapn://"));

    const recanonical = try syrup.canonicalHandoffGiveSignedBytes(allocator, owned_give);
    defer allocator.free(recanonical);
    const carried = crypto.Signature.fromBytes(owned_give.signature[0..crypto.SIGNATURE_BYTES].*);
    try crypto.verify(gifter_secret.publicKey(), recanonical, carried);
}
