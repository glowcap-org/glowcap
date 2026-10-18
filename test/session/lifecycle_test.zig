//! The session's own life: negotiating through open to closed, the two
//! start-session halves and their rejections, version mismatch on both
//! directions, negotiated features, identical handshake recording on owned
//! and borrowed paths, and preference hints.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

test "session lifecycle moves from negotiating through open to closed" {
    const allocator = std.testing.allocator;
    var s = session.Session.initNegotiating(allocator);
    defer s.deinit();
    try std.testing.expectEqual(session.State.negotiating, s.state);

    try s.transitionToOpen();
    try std.testing.expectEqual(session.State.open, s.state);

    s.close();
    try std.testing.expectEqual(session.State.closed, s.state);
}

test "start-session handshake transitions to open and installs bootstrap export" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    // Local half first: stays negotiating until the partner's half lands.
    try s.recordSend(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.negotiating, s.state);
    try std.testing.expect(!s.handshakeComplete());
    try std.testing.expect(!s.hasExport(.from(session.bootstrap_position)));

    // Partner half completes the handshake → open + bootstrap export@0.
    try s.recordRecv(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.open, s.state);
    try std.testing.expect(s.handshakeComplete());
    try std.testing.expect(s.hasExport(.from(session.bootstrap_position)));
}

test "start-session is rejected outside the negotiating state" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator); // starts open
    defer s.deinit();
    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        s.recordSend(startSessionMessage(.v1_0)),
    );
}

test "negotiating session refuses non-handshake traffic" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(7));
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = null,
            .resolve_me_desc = null,
        },
    }));
}

test "duplicate start-session halves are rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try s.recordSend(startSessionMessage(.v1_0));
    try std.testing.expectError(
        session.Error.DuplicateStartSession,
        s.recordSend(startSessionMessage(.v1_0)),
    );

    try s.recordRecv(startSessionMessage(.v1_0));
    // Now open; a further inbound start-session is rejected as unexpected.
    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        s.recordRecv(startSessionMessage(.v1_0)),
    );
}

test "a second inbound start-session half is rejected while negotiating" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try s.recordRecv(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.negotiating, s.state); // local half still pending
    try std.testing.expectError(
        session.Error.DuplicateStartSession,
        s.recordRecv(startSessionMessage(.v1_0)),
    );
}

test "start-session with a mismatched captp version is rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try std.testing.expectError(
        session.Error.CaptpVersionMismatch,
        s.recordRecv(startSessionMessage(.next)),
    );
}

test "outbound start-session with a mismatched captp version is rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try std.testing.expectError(
        session.Error.CaptpVersionMismatch,
        s.recordSend(startSessionMessage(.next)),
    );
    try std.testing.expect(!s.handshake_local_sent);
    try std.testing.expectEqual(session.State.negotiating, s.state);
}

test "session stores selected CapTP version and negotiated features" {
    const features = model.FeatureSet{
        .pipelining = true,
        .handoff = false,
        .wire_delta = true,
        .sturdyref = false,
    };
    var s = session.Session.initWith(std.testing.allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = features,
    });
    defer s.deinit();

    try std.testing.expectEqual(model.CaptpVersion.v1_0, s.captp_version);
    try std.testing.expect(s.needsV1_0Translation());
    try std.testing.expect(s.features.pipelining);
    try std.testing.expect(s.features.wire_delta);
    try std.testing.expect(!s.features.handoff);
}

test "owned and borrowed recv paths record the partner handshake identically" {
    const allocator = std.testing.allocator;

    var owned_path = session.Session.initWith(allocator, .{ .negotiating = true });
    defer owned_path.deinit();
    var view_path = session.Session.initWith(allocator, .{ .negotiating = true });
    defer view_path.deinit();

    const message = startSessionMessage(.v1_0);
    try owned_path.recordRecv(message);
    try view_path.recordRecvView(model.view.Body.fromOwned(&message));

    // One shared apply body serves both paths, so the partner's session key
    // and location designator land regardless of which representation carried
    // the handshake. The owned path must set both.
    inline for (.{ &owned_path, &view_path }) |s| {
        try std.testing.expectEqualSlices(
            u8,
            &.{ 0xaa, 0xbb },
            s.partnerSessionKey() orelse return error.TestUnexpectedResult,
        );
        try std.testing.expectEqualStrings(
            "peer",
            s.partnerDesignator() orelse return error.TestUnexpectedResult,
        );
    }
}

test "preference hints on the owned path refuse duplicates, wrong types, and unreadable tokens" {
    // The borrowed-view refusals live in the codec tests; these pin the owned
    // `model.Hints` arms of the same one parser, which apply and the
    // advertised-profile checks walk.
    const transport = model.transport;

    const duplicate = [_]model.HintEntry{
        .{ .name = transport.hint_codec, .value = .{ .string = "1" } },
        .{ .name = transport.hint_codec, .value = .{ .string = "1" } },
    };
    try std.testing.expectError(
        session.Error.MalformedMessage,
        session.parsePreferenceHints(model.Hints{ .entries = &duplicate }),
    );

    const non_string = [_]model.HintEntry{
        .{ .name = transport.hint_codec, .value = .{ .integer = 1 } },
    };
    try std.testing.expectError(
        session.Error.MalformedMessage,
        session.parsePreferenceHints(model.Hints{ .entries = &non_string }),
    );

    const bad_codec_token = [_]model.HintEntry{
        .{ .name = transport.hint_codec, .value = .{ .string = "bad" } },
    };
    try std.testing.expectError(
        session.Error.MalformedMessage,
        session.parsePreferenceHints(model.Hints{ .entries = &bad_codec_token }),
    );

    const bad_features = [_]model.HintEntry{
        .{ .name = transport.hint_features, .value = .{ .string = "pipelining,,handoff" } },
    };
    try std.testing.expectError(
        session.Error.MalformedMessage,
        session.parsePreferenceHints(model.Hints{ .entries = &bad_features }),
    );
}

test "preference hints read a token this build does not write as the baseline" {
    const transport = model.transport;
    const unknown = [_]model.HintEntry{
        .{ .name = transport.hint_captp_version, .value = .{ .string = "ocapn-2" } },
        .{ .name = transport.hint_codec, .value = .{ .string = "0/0123456789abcdef" } },
        .{ .name = transport.hint_features, .value = .{ .string = "no-such-feature,sturdyref" } },
    };
    const preference = try session.parsePreferenceHints(model.Hints{ .entries = &unknown });
    try std.testing.expectEqual(model.Preference.baseline.captp_version, preference.captp_version);
    try std.testing.expectEqual(model.Preference.baseline.codec, preference.codec);
    try std.testing.expectEqual(model.FeatureSet{ .sturdyref = true }, preference.features);
}

test "preference hints on the owned path parse a stated profile" {
    const transport = model.transport;
    const stated = [_]model.HintEntry{
        .{ .name = transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.hintToken() } },
    };
    const preference = try session.parsePreferenceHints(model.Hints{ .entries = &stated });
    try std.testing.expectEqual(model.CaptpVersion.next, preference.captp_version);
    try std.testing.expectEqual(model.Preference.baseline.codec, preference.codec);
    try std.testing.expectEqual(model.Preference.baseline.features, preference.features);
}
