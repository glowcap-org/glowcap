//! Handoff and feature gates at the session boundary: nested gives need the
//! negotiated feature, inbound admission checks recipient and gift-id domain
//! atomically, outbound gives need the partner session key, and listen and
//! sturdyref payloads stay behind their gates.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;
const crypto = glowcap.foundation.crypto;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

test "nested handoff values require the negotiated handoff feature" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .features = .{
        .pipelining = true,
        .handoff = false,
        .wire_delta = true,
        .sturdyref = true,
    } });
    defer s.deinit();
    try s.registerImport(.from(7));
    try s.registerExport(.from(8));

    var handoff: model.Handoff = .{ .give = .{
        .recipient_key = "recipient",
        .exporter = .{ .transport = "onion", .designator = "exporter" },
        .gifter_exporter_session = "session",
        .gifter_side = "gifter",
        .gift_id = "gift",
        .signature = "signature",
    } };
    var args = [_]model.Argument{.{ .handoff = &handoff }};

    const outbound = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } };
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(outbound));

    const inbound = model.Message{ .deliver = .{
        .target = .{ .near = model.NearRef.object(8) },
        .args = &args,
    } };
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordRecv(inbound));
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordRecvView(model.view.Body.fromOwned(&inbound)));
}

test "session rejects a malformed nested handoff give" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(1));

    var handoff = model.Handoff{ .give = .{
        .recipient_key = &.{},
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = &.{},
        .gifter_side = &.{},
        .gift_id = &.{},
        .signature = &.{},
    } };
    try std.testing.expectError(session.Error.MalformedMessage, s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{.{ .handoff = &handoff }},
    } }));
}

test "inbound give admission rejects wrong recipient and gift width atomically" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .captp_version = .v1_0,
    });
    defer {
        failing.fail_index = std.math.maxInt(usize);
        s.deinit();
    }

    const local_key = @as([32]u8, @splat(0x31));
    const remote_key = @as([32]u8, @splat(0x32));
    try s.recordSend(startSessionMessageWithKey(.v1_0, &local_key));
    try s.recordRecv(startSessionMessageWithKey(.v1_0, &remote_key));
    s.captp_version = .next;

    const session_name = @as([32]u8, @splat(0x41));
    const gifter_side = @as([32]u8, @splat(0x42));
    const valid_gift_id = @as([model.handoff_gift_id_bytes]u8, @splat(0x43));
    const wrong_key = @as([32]u8, @splat(0x44));
    var handoff = model.Handoff{ .give = .{
        .recipient_key = &wrong_key,
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = &session_name,
        .gifter_side = &gifter_side,
        .gift_id = &valid_gift_id,
        .signature = "signature",
    } };
    var inbound = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(session.bootstrap_position) } },
        .args = &.{.{ .handoff = &handoff }},
        .answer = .from(41),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } };

    // No allocation is available after handshake. Admission must refuse before
    // answer installation or any downstream Host locator/dial work.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(session.Error.InvalidGift, s.recordRecv(inbound));
    try std.testing.expect(s.inboundAnswer(.from(41)) == null);
    try std.testing.expectError(session.Error.InvalidGift, s.recordRecvView(model.view.Body.fromOwned(&inbound)));
    try std.testing.expect(s.inboundAnswer(.from(41)) == null);

    handoff.give.recipient_key = &local_key;
    handoff.give.gift_id = "short";
    inbound.deliver.answer = .from(42);
    try std.testing.expectError(session.Error.MalformedMessage, s.recordRecv(inbound));
    try std.testing.expect(s.inboundAnswer(.from(42)) == null);
    try std.testing.expectError(session.Error.MalformedMessage, s.recordRecvView(model.view.Body.fromOwned(&inbound)));
    try std.testing.expect(s.inboundAnswer(.from(42)) == null);
}

test "v1 inbound give admission enforces recipient and gift-id domain" {
    var s = session.Session.initWith(std.testing.allocator, .{ .negotiating = true });
    defer s.deinit();

    const local_key = @as([32]u8, @splat(0x51));
    const remote_key = @as([32]u8, @splat(0x52));
    try s.recordSend(startSessionMessageWithKey(.v1_0, &local_key));
    try s.recordRecv(startSessionMessageWithKey(.v1_0, &remote_key));

    const valid_gift_id = @as([model.handoff_gift_id_bytes]u8, @splat(0x53));
    var handoff = model.Handoff{ .give = .{
        .recipient_key = "not-this-session-key",
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = "session",
        .gifter_side = "gifter",
        .gift_id = &valid_gift_id,
        .signature = "signature",
    } };
    var inbound = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(session.bootstrap_position) } },
        .args = &.{.{ .handoff = &handoff }},
        .answer = .from(51),
    } };

    try std.testing.expectError(session.Error.InvalidGift, s.recordRecv(inbound));
    try std.testing.expect(s.inboundAnswer(.from(51)) == null);
    try std.testing.expectError(session.Error.InvalidGift, s.recordRecvView(model.view.Body.fromOwned(&inbound)));
    try std.testing.expect(s.inboundAnswer(.from(51)) == null);

    // A short gift id is admitted here: refusing one retires the session before
    // the handoff is read, and the pinned suite gives `my-gift` (ocapn-findings).
    handoff.give.recipient_key = &local_key;
    handoff.give.gift_id = "short";
    inbound.deliver.answer = .from(52);
    try s.recordRecv(inbound);
    try std.testing.expect(s.inboundAnswer(.from(52)) != null);
}

test "outbound give admission requires the partner session key" {
    var s = session.Session.initWith(std.testing.allocator, .{ .negotiating = true });
    defer s.deinit();

    const local_key = @as([32]u8, @splat(0x61));
    const partner_key = @as([32]u8, @splat(0x62));
    const gift_id = @as([model.handoff_gift_id_bytes]u8, @splat(0x63));
    try s.recordSend(startSessionMessageWithKey(.v1_0, &local_key));
    try s.recordRecv(startSessionMessageWithKey(.v1_0, &partner_key));

    var handoff = model.Handoff{ .give = .{
        .recipient_key = &local_key,
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = "session",
        .gifter_side = "gifter",
        .gift_id = &gift_id,
        .signature = "signature",
    } };
    const outbound = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(session.bootstrap_position) },
        .args = &.{.{ .handoff = &handoff }},
    } };

    try std.testing.expectError(session.Error.InvalidGift, s.recordSend(outbound));

    handoff.give.recipient_key = &partner_key;
    try s.recordSend(outbound);
}

test "session feature gates listen and sturdyref-bearing payloads" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .features = model.FeatureSet.minimum(),
    });
    defer s.deinit();
    try s.registerImport(.from(1));
    try s.registerExport(.from(2));

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .listen = .{
            .target = .{ .far = .{ .import_position = .from(1) } },
            .listener = .{ .near = .{ .export_position = .from(2) } },
            .mode = .settling_only,
        },
    }));

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(1) } },
            .args = &.{.{ .reference = .{ .sturdy = &.{
                .peer = .{ .transport = "memory", .designator = "host" },
                .swissnum = &.{ 1, 2, 3 },
            } } }},
            .answer = null,
        },
    }));

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordRecv(.{
        .gc_export = .{
            .positions = &.{2},
            .deltas = &.{1},
        },
    }));
}

test "identity-route locators require the negotiated feature in sturdyrefs" {
    const allocator = std.testing.allocator;
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x70))).publicKey().toDesignator();
    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route);
    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route },
    }};
    const sturdy: model.Reference = .{ .sturdy = &.{
        .peer = .{
            .transport = model.transport.id,
            .designator = &key,
            .hints = .{ .entries = &hints },
        },
        .swissnum = &.{ 1, 2, 3 },
    } };

    var default_features = session.Session.initWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.defaultOffer(),
    });
    defer default_features.deinit();
    try default_features.registerImport(.from(1));
    try default_features.registerExport(.from(2));
    try std.testing.expectError(session.Error.FeatureNotNegotiated, default_features.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{.{ .reference = sturdy }},
    } }));
    const inbound = model.Message{ .deliver = .{
        .target = .{ .near = model.NearRef.object(2) },
        .args = &.{.{ .reference = sturdy }},
    } };
    try std.testing.expectError(session.Error.FeatureNotNegotiated, default_features.recordRecv(inbound));
    try std.testing.expectError(
        session.Error.FeatureNotNegotiated,
        default_features.recordRecvView(model.view.Body.fromOwned(&inbound)),
    );

    var opted_in = session.Session.initWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer opted_in.deinit();
    try opted_in.registerImport(.from(1));
    try opted_in.registerExport(.from(2));
    try opted_in.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{.{ .reference = sturdy }},
    } });
    try opted_in.recordRecv(inbound);
}

test "sturdyref locators must be structurally valid" {
    const allocator = std.testing.allocator;
    const duplicate_hints = [_]model.HintEntry{
        .{
            .name = "route",
            .value = .{ .string = "one" },
        },
        .{
            .name = "route",
            .value = .{ .string = "two" },
        },
    };
    const empty_name_hint = [_]model.HintEntry{.{
        .name = "",
        .value = .{ .string = "value" },
    }};
    const invalid_false_hint = [_]model.HintEntry{.{
        .name = "route",
        .value = .{ .string = "value" },
    }};
    const locators = [_]model.PeerLocator{
        .{
            .transport = "tcp",
            .designator = "127.0.0.1:9048",
            .hints = .{ .entries = &duplicate_hints },
        },
        .{
            .transport = "tcp",
            .designator = "127.0.0.1:9048",
            .hints = .{ .entries = &empty_name_hint },
        },
        .{
            .transport = "tcp",
            .designator = "127.0.0.1:9048",
            .hints = .{ .entries = &invalid_false_hint, .wire_form = .boolean_false },
        },
    };

    var s = session.Session.initWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(1));
    try s.registerExport(.from(2));

    for (locators) |peer| {
        const sturdyref: model.SturdyRef = .{ .peer = peer, .swissnum = &.{ 1, 2, 3 } };
        const sturdy: model.Reference = .{ .sturdy = &sturdyref };
        try std.testing.expectError(session.Error.MalformedMessage, s.recordSend(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(1) },
            .args = &.{.{ .reference = sturdy }},
        } }));
        const inbound = model.Message{ .deliver = .{
            .target = .{ .near = model.NearRef.object(2) },
            .args = &.{.{ .reference = sturdy }},
        } };
        try std.testing.expectError(session.Error.MalformedMessage, s.recordRecv(inbound));
        try std.testing.expectError(
            session.Error.MalformedMessage,
            s.recordRecvView(model.view.Body.fromOwned(&inbound)),
        );
    }
}

test "identity-route locators require the negotiated feature in handoff gives" {
    const allocator = std.testing.allocator;
    const exporter_key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x74))).publicKey().toDesignator();
    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{exporter_key[0..]});
    defer allocator.free(route);
    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route },
    }};
    const partner_key = @as([32]u8, @splat(0x72));
    const gift_id = @as([model.handoff_gift_id_bytes]u8, @splat(0x73));
    var handoff = model.Handoff{ .give = .{
        .recipient_key = &partner_key,
        .exporter = .{
            .transport = model.transport.id,
            .designator = &exporter_key,
            .hints = .{ .entries = &hints },
        },
        .gifter_exporter_session = "session",
        .gifter_side = "gifter",
        .gift_id = &gift_id,
        .signature = "signature",
    } };

    var s = session.Session.initWith(allocator, .{ .negotiating = true });
    defer s.deinit();
    const local_key = @as([32]u8, @splat(0x71));
    try s.recordSend(startSessionMessageWithKey(.v1_0, &local_key));
    try s.recordRecv(startSessionMessageWithKey(.v1_0, &partner_key));
    try s.registerImport(.from(1));
    try s.registerExport(.from(2));

    const outbound = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{.{ .handoff = &handoff }},
    } };
    const inbound = model.Message{ .deliver = .{
        .target = .{ .near = model.NearRef.object(2) },
        .args = &.{.{ .handoff = &handoff }},
        .answer = .from(61),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } };

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(outbound));
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordRecv(inbound));
    try std.testing.expect(s.inboundAnswer(.from(61)) == null);
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordRecvView(model.view.Body.fromOwned(&inbound)));
    try std.testing.expect(s.inboundAnswer(.from(61)) == null);

    s.features = model.FeatureSet.full();
    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(outbound));

    s.captp_version = .next;
    try s.recordSend(outbound);
    handoff.give.recipient_key = &local_key;
    try s.recordRecv(inbound);
}

test "listen target and listener descriptor roles match on owned and borrowed paths" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(1));
    _ = try s.nominateShorteningResolver(.from(1));
    try s.registerExport(.from(2));
    try s.registerExport(.from(3));

    // Open one answer in each direction. They are the only integers legal in a
    // `desc:answer` target on their respective paths.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{},
        .answer = .from(20),
        .listen_mode = .shortening_only,
    } });
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(3) },
        .args = &.{},
        .answer = .from(30),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });

    // Outbound: target is the partner's export or our live answer; listener is
    // our export and therefore encodes as desc:import-*.
    try s.recordSend(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .shortening_or_settling,
    } });
    try s.recordSend(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(20) } },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .settling_only,
    } });
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .listen = .{
        .target = .{ .near = model.NearRef.object(3) },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .settling_only,
    } }));
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .listener = .{ .far = model.FarRef.object(1) },
        .mode = .settling_only,
    } }));
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(99) } },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .settling_only,
    } }));

    // Inbound roles are the exact perspective flip. A failed listen does not
    // install the introduced listener import on either recv representation.
    const valid_inbound = model.Message{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(30) } },
        .listener = .{ .far = model.FarRef.object(4) },
        .mode = .settling_only,
    } };
    const wrong_target = model.Message{ .listen = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .listener = .{ .far = model.FarRef.object(4) },
        .mode = .settling_only,
    } };
    const wrong_listener = model.Message{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(30) } },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .settling_only,
    } };
    const dead_answer = model.Message{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(99) } },
        .listener = .{ .far = model.FarRef.object(4) },
        .mode = .settling_only,
    } };
    inline for (.{ wrong_target, wrong_listener, dead_answer }) |invalid| {
        try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&invalid)));
        try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(invalid));
        try std.testing.expect(!s.hasImport(.from(4)));
    }
    try s.recordRecvView(model.view.Body.fromOwned(&valid_inbound));
    try s.recordRecv(valid_inbound);

    // GC, rather than settlement, ends answer-target liveness in both
    // directions.
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{20} } });
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(20) } },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .settling_only,
    } }));
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{30} } });
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&valid_inbound)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(valid_inbound));
}
