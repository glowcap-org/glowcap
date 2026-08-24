//! Handshake admission for pancake-next identity routes: `id/via` remains
//! silent without bilateral opt-in, and admitted plans are complete,
//! unambiguous, and prove the outer identity.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const handshake = @import("../../support/handshake.zig");

const crypto = foundation.crypto;

fn idHelloFrame(
    allocator: std.mem.Allocator,
    remote_secret: crypto.SecretKey,
    id_designator: []const u8,
    via: ?[]const u8,
    extra: ?model.HintEntry,
) !foundation.Frame {
    var feature_bytes: [model.FeatureSet.wire_string_max_len]u8 = undefined;
    const features = try model.FeatureSet.full().toWireString(&feature_bytes);
    var hints: [4]model.HintEntry = undefined;
    hints[0] = .{ .name = model.transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.wireString() } };
    hints[1] = .{ .name = model.transport.hint_features, .value = .{ .string = features } };
    var hint_count: usize = 2;
    if (via) |routes| {
        hints[hint_count] = .{ .name = model.transport.hint_via, .value = .{ .string = routes } };
        hint_count += 1;
    }
    if (extra) |entry| {
        hints[hint_count] = entry;
        hint_count += 1;
    }
    return handshake.signedHelloFrame(
        allocator,
        remote_secret,
        model.transport.id,
        id_designator,
        .{ .entries = hints[0..hint_count] },
    );
}

fn receiveIdHello(
    allocator: std.mem.Allocator,
    id_designator: []const u8,
    via: ?[]const u8,
) !engine.Peer {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    errdefer peer.deinit();

    const local_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x51)));
    try peer.sendKeyedStartSession(.{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    }, local_secret);
    _ = try peer.step();
    var outbound = peer.takeOutbound().?;
    outbound.deinit();

    const remote_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x52)));
    try peer.feedOwned(try idHelloFrame(allocator, remote_secret, id_designator, via, null));
    return peer;
}

test "identity-route hellos cannot be the unnegotiated first hello" {
    const allocator = std.testing.allocator;
    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x49)));
    const key = secret.publicKey().toDesignator();
    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route);
    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route },
    }};
    const loc: model.PeerLocator = .{
        .transport = model.transport.id,
        .designator = &key,
        .hints = .{ .entries = &hints },
    };

    var default_peer = engine.Peer.initNegotiating(allocator);
    defer default_peer.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, default_peer.sendKeyedStartSession(loc, secret));
    try std.testing.expect(!default_peer.session_state.handshake_local_sent);

    var v1_feature_only = engine.Peer.initNegotiatingWith(allocator, .{
        .features = model.FeatureSet.full(),
    });
    defer v1_feature_only.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, v1_feature_only.sendKeyedStartSession(loc, secret));
    try std.testing.expect(!v1_feature_only.session_state.handshake_local_sent);

    var opted_in_first_hello = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer opted_in_first_hello.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, opted_in_first_hello.sendKeyedStartSession(loc, secret));
    try std.testing.expect(!opted_in_first_hello.session_state.handshake_local_sent);
}

test "identity-route hellos require local and remote opt-in" {
    const allocator = std.testing.allocator;
    const remote_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x4a)));
    const key = remote_secret.publicKey().toDesignator();
    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route);
    const frame = try idHelloFrame(allocator, remote_secret, &key, route, null);

    var default_receiver = engine.Peer.initNegotiating(allocator);
    defer default_receiver.deinit();
    try default_receiver.feedOwned(frame);
    try std.testing.expectError(session.Error.MalformedMessage, default_receiver.step());
    try std.testing.expect(!default_receiver.session_state.handshake_remote_received);
    try std.testing.expectEqual(session.State.closed, default_receiver.session_state.state);
}

test "identity-route hellos admit only complete same-key carrier plans" {
    const allocator = std.testing.allocator;
    const id_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x53)));
    const id_designator = id_secret.publicKey().toDesignator();
    const other_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x54)));
    const other_designator = other_secret.publicKey().toDesignator();

    var missing = try receiveIdHello(allocator, &id_designator, null);
    defer missing.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, missing.step());
    try std.testing.expect(!missing.session_state.handshake_remote_received);

    const wrong_route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{other_designator});
    defer allocator.free(wrong_route);
    var mismatched = try receiveIdHello(allocator, &id_designator, wrong_route);
    defer mismatched.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, mismatched.step());
    try std.testing.expect(!mismatched.session_state.handshake_remote_received);

    var unsupported = try receiveIdHello(allocator, &id_designator, "ocapn://127.0.0.1%3A9000.tcp");
    defer unsupported.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, unsupported.step());
    try std.testing.expect(!unsupported.session_state.handshake_remote_received);

    const valid_route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{id_designator});
    defer allocator.free(valid_route);
    var valid = try receiveIdHello(allocator, &id_designator, valid_route);
    defer valid.deinit();
    _ = try valid.step();
    try std.testing.expect(valid.session_state.handshake_remote_received);
    try std.testing.expectEqual(session.State.open, valid.session_state.state);
}

test "identity-route hello refuses duplicate nested route hints" {
    const allocator = std.testing.allocator;
    const id_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x55)));
    const id_designator = id_secret.publicKey().toDesignator();
    const duplicate = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.iroh?relay=one&relay=two",
        .{id_designator},
    );
    defer allocator.free(duplicate);

    var peer = try receiveIdHello(allocator, &id_designator, duplicate);
    defer peer.deinit();
    try std.testing.expectError(session.Error.MalformedMessage, peer.step());
    try std.testing.expect(!peer.session_state.handshake_remote_received);
}

test "identity-route hello admits a weak baseline handoff fallback" {
    const allocator = std.testing.allocator;
    const remote_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x58)));
    const remote_designator = remote_secret.publicKey().toDesignator();
    const via = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{remote_designator});
    defer allocator.free(via);
    const onion = "ocapn://baseline-service.onion";

    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer peer.deinit();
    try peer.feedOwned(try idHelloFrame(
        allocator,
        remote_secret,
        &remote_designator,
        via,
        .{
            .name = model.transport.hint_alt_locators,
            .value = .{ .string = onion },
        },
    ));
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expect(peer.session_state.handshake_remote_received);
    try std.testing.expectEqual(session.State.negotiating, peer.session_state.state);
}

test "identity-route hello is admitted before the local hello" {
    const allocator = std.testing.allocator;
    const remote_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x56)));
    const remote_designator = remote_secret.publicKey().toDesignator();
    const via = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{remote_designator});
    defer allocator.free(via);

    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer peer.deinit();
    try peer.feedOwned(try idHelloFrame(allocator, remote_secret, &remote_designator, via, null));
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expect(peer.session_state.handshake_remote_received);
    try std.testing.expect(!peer.sessionIsOpen());

    const local_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x57)));
    try peer.sendKeyedStartSession(.{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    }, local_secret);
    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expect(peer.session_state.features.multi_location);
}
