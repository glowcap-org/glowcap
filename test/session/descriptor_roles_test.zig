//! CapTP target and listener roles and their actual session authority.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

test "descriptor roles require a live outbound question for a deliver target" {
    const allocator = std.testing.allocator;
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var s = session.Session.initWith(allocator, .{ .captp_version = profile });
        defer s.deinit();
        try s.registerImport(.from(7));
        try s.registerExport(.from(8));

        const export_count = s.exportRefcount(.from(8));
        const local = try s.nominateResolverExport();
        const invalid_targets = [_]model.Reference{
            .{ .near = model.NearRef.object(8) },
            .{ .far = model.FarRef.object(9) },
            .{ .promise = .{ .answer_position = .from(99) } },
            .{ .promise = .{ .answer_position = local.answer } },
        };
        for (invalid_targets) |target| {
            try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .deliver = .{
                .target = target,
                .args = &.{},
                .answer = .from(40),
            } }));
            try std.testing.expectEqual(export_count, s.exportRefcount(.from(8)));
            try std.testing.expect(s.outboundAnswer(.from(40)) == null);
        }

        if (profile == .next) {
            // Next requires the inline resolver to be the sender's export.
            try std.testing.expectError(error.UnexpectedMessage, s.recordSend(.{ .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &.{},
                .answer = .from(41),
                .resolve_me_desc = .{ .far = model.FarRef.object(7) },
            } }));
            try std.testing.expect(s.outboundAnswer(.from(41)) == null);
        }

        // A prior call creates answer 11. It remains addressable after settlement
        // and stops being addressable only when our op:gc-answers releases it.
        try s.recordSend(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{},
            .answer = .from(11),
        } });
        try s.recordRecv(.{ .resolve = .{
            .answer = .from(11),
            .resolution = .{ .fulfill = .{ .void = {} } },
        } });
        try std.testing.expectEqual(.fulfilled, s.outboundAnswer(.from(11)).?.status);
        try s.recordSend(.{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(11) } },
            .args = &.{},
            .answer = .from(12),
        } });
        try s.recordSend(.{ .gc_answer = .{ .positions = &.{11} } });
        try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(11) } },
            .args = &.{},
            .answer = .from(42),
        } }));
        try std.testing.expect(s.outboundAnswer(.from(42)) == null);
    }
}

test "descriptor roles reject invalid inbound delivers before installing authority" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    const invalid_targets = [_]model.Reference{
        .{ .far = model.FarRef.object(7) },
        .{ .far = model.FarRef.object(9) },
        .{ .promise = .{ .answer_position = .from(77) } },
    };
    for (invalid_targets) |target| {
        const invalid: model.Message = .{ .deliver = .{
            .target = target,
            .args = &.{.{ .reference = .{ .far = model.FarRef.object(10) } }},
            .answer = .from(1),
        } };
        try std.testing.expectError(error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&invalid)));
        try std.testing.expect(s.inboundAnswer(.from(1)) == null);
        try std.testing.expect(!s.hasImport(.from(10)));
        try std.testing.expectError(error.InvalidReference, s.recordRecv(invalid));
        try std.testing.expect(s.inboundAnswer(.from(1)) == null);
        try std.testing.expect(!s.hasImport(.from(10)));
    }

    // The same answer is valid while pending and settled, then invalid after
    // the partner releases it with op:gc-answers.
    try s.registerExport(.from(8));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(8) },
        .args = &.{},
        .answer = .from(77),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });
    const live_answer = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(77) } },
        .args = &.{},
    } };
    try s.recordRecv(live_answer);
    try s.recordRecvView(model.view.Body.fromOwned(&live_answer));
    try s.recordSend(.{ .resolve = .{
        .answer = .from(77),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    try std.testing.expectEqual(.fulfilled, s.inboundAnswer(.from(77)).?.status);
    try s.recordRecv(live_answer);
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{77} } });
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&live_answer)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(live_answer));
}

test "descriptor roles separate listen targets from listeners on both receive paths" {
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

    const near_listener: model.Reference = .{ .near = model.NearRef.object(2) };
    const far_listener: model.Reference = .{ .far = model.FarRef.object(4) };
    const outbound_target: model.Reference = .{ .far = model.FarRef.promise(1) };
    const our_question: model.Reference = .{ .promise = .{ .answer_position = .from(20) } };
    const their_question: model.Reference = .{ .promise = .{ .answer_position = .from(30) } };
    const no_question: model.Reference = .{ .promise = .{ .answer_position = .from(99) } };
    try s.recordSend(.{ .listen = .{ .target = outbound_target, .listener = near_listener, .mode = .shortening_or_settling } });
    const live_outbound: model.Message = .{ .listen = .{ .target = our_question, .listener = near_listener, .mode = .settling_only } };
    try s.recordSend(live_outbound);

    const Listen = @FieldType(model.Message, "listen");
    for ([_]Listen{
        .{ .target = .{ .near = model.NearRef.object(3) }, .listener = near_listener, .mode = .settling_only },
        .{ .target = outbound_target, .listener = .{ .far = model.FarRef.object(1) }, .mode = .settling_only },
        .{ .target = no_question, .listener = near_listener, .mode = .settling_only },
        .{ .target = their_question, .listener = near_listener, .mode = .settling_only },
    }) |invalid| try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .listen = invalid }));

    for ([_]Listen{
        .{ .target = outbound_target, .listener = far_listener, .mode = .settling_only },
        .{ .target = their_question, .listener = near_listener, .mode = .settling_only },
        .{ .target = no_question, .listener = far_listener, .mode = .settling_only },
        .{ .target = our_question, .listener = far_listener, .mode = .settling_only },
    }) |item| {
        const invalid: model.Message = .{ .listen = item };
        try std.testing.expectError(error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&invalid)));
        try std.testing.expect(!s.hasImport(.from(4)));
        try std.testing.expectError(error.InvalidReference, s.recordRecv(invalid));
        try std.testing.expect(!s.hasImport(.from(4)));
    }
    const valid_inbound: model.Message = .{ .listen = .{ .target = their_question, .listener = far_listener, .mode = .settling_only } };
    try s.recordRecvView(model.view.Body.fromOwned(&valid_inbound));
    try s.recordRecv(valid_inbound);

    // GC, rather than settlement, ends answer-target liveness in both
    // directions.
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{20} } });
    try std.testing.expectError(error.InvalidReference, s.recordSend(live_outbound));
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{30} } });
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&valid_inbound)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(valid_inbound));
}
