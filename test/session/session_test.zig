const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const session = pancake.ocapn.session;

test "open session accepts outbound deliver to a registered import" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(7);
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
        },
    };

    try s.recordSend(message);
}

test "open session accepts an outbound deliver to the partner bootstrap without registering it" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    // No registerImport(BOOTSTRAP_POSITION): the partner bootstrap (import 0) is
    // always reachable on an open session — the bootstrap-fetch send target.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = session.BOOTSTRAP_POSITION } },
            .args = &.{ .{ .symbol = "fetch" }, .{ .bytes = "swiss" } },
            .answer = 1,
        },
    };
    try s.recordSend(message);

    // Any other unheld import is still a loud authority error.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{.{ .bytes = "x" }},
            .answer = 2,
        },
    }));
}

test "closed session rejects outbound traffic" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.close();

    const message = model.Message{
        .abort = .{ .kind = .other, .message = "closed" },
    };

    try std.testing.expectError(session.Error.SessionClosed, s.recordSend(message));
}

test "inbound abort closes session" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    const message = model.Message{
        .abort = .{ .kind = .other, .message = "bye" },
    };

    try s.recordRecv(message);

    try std.testing.expectEqual(session.State.closed, s.state);
}

test "session records outbound answers from sent deliver" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(7);

    try s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
        },
    });

    try std.testing.expect(s.outboundAnswer(42) != null);
    try std.testing.expectEqual(session.AnswerStatus.pending, s.outboundAnswer(42).?.status);
}

test "inbound deliver nested past max_nesting_depth fails closed" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);

    // Build an argument tree nested deeper than the cap. A bump arena owns the
    // scratch tree; the test only needs it to live across the one recordRecv.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cap = (session.SessionLimits{}).max_nesting_depth;
    var node = try a.alloc(model.Argument, 1);
    node[0] = .{ .integer = 1 };
    var level: usize = 0;
    while (level < cap + 5) : (level += 1) {
        const wrap = try a.alloc(model.Argument, 1);
        wrap[0] = .{ .list = node };
        node = wrap;
    }

    // The recursive validate walk hits the cap and fails loud instead of
    // overflowing the native stack — a one-frame DoS becomes a typed error
    // that the runtime projects to a `resource_exhausted` op:abort.
    try std.testing.expectError(session.Error.NestingTooDeep, s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = 7 } },
            .args = node,
            .answer = null,
        },
    }));

    // A tree at the cap is accepted.
    var ok_node = try a.alloc(model.Argument, 1);
    ok_node[0] = .{ .integer = 1 };
    var ok_level: usize = 0;
    // cap-1 wraps over the base list keeps total nesting within the bound.
    while (ok_level < cap - 1) : (ok_level += 1) {
        const wrap = try a.alloc(model.Argument, 1);
        wrap[0] = .{ .list = ok_node };
        ok_node = wrap;
    }
    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = 7 } },
            .args = ok_node,
            .answer = null,
        },
    });
}

test "session records inbound answers and settles on resolve" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);

    // Inbound deliver to our export 7. Post-flip (ADR-0010) the wire
    // `<desc:export 7>` decodes to `.near{export_position=7}` in our perspective.
    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 11,
        },
    });
    try std.testing.expect(s.inboundAnswer(11) != null);

    try s.recordSend(.{
        .resolve = .{
            .answer = 11,
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    });

    try std.testing.expectEqual(session.AnswerStatus.fulfilled, s.inboundAnswer(11).?.status);
}

test "inbound deliver to an unheld far target is rejected on both recv paths" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Import 7 is not held, so a deliver whose *target* is far import 7 names a
    // capability that does not exist for us. The borrowed steady-state path
    // (`recordRecvView`) and the owned retain path (`recordRecv`) share one
    // target-reference rule, so both must reject it as `InvalidReference`. The
    // view path previously accepted any far target — this is the regression guard.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{.{ .bytes = "x" }},
            .answer = 1,
        },
    };

    try std.testing.expectError(
        session.Error.InvalidReference,
        s.recordRecvView(model.view.Body.fromOwned(&message)),
    );
    try std.testing.expectError(
        session.Error.InvalidReference,
        s.recordRecv(message),
    );
}

test "inbound deliver to a held far target is accepted through the borrowed path" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(7);

    // The strict target rule accepts a far target we *do* hold — it rejects only
    // unheld ones, so the borrowed walker is not simply refusing every far.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{.{ .bytes = "x" }},
            .answer = 1,
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&message));
    try std.testing.expect(s.inboundAnswer(1) != null);
}

test "a reference inside a Struct argument crosses every session walk" {
    // Struct entries carry full argument values (ADR-0046), so a reference can
    // ride inside one. Regression guard: the argument walkers previously
    // recursed through list/set/tagged but skipped struct entries, so a
    // struct-wrapped reference dodged outbound validation, introduced-import
    // installation, and sent-export retention.
    const allocator = std.testing.allocator;

    // Outbound: a near reference naming an unregistered export, wrapped in a
    // struct entry, is still an authority error.
    {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerImport(7);
        try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
            .deliver = .{
                .target = .{ .far = .{ .import_position = 7 } },
                .args = &.{.{ .@"struct" = &.{
                    .{ .key = "cap", .value = .{ .reference = .{ .near = .{ .export_position = 99 } } } },
                } }},
                .answer = 1,
            },
        }));
    }

    // Outbound: a held export named through a struct entry is retained, so the
    // partner's later gc-exports delta cannot underflow the table.
    {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerImport(7);
        try s.registerExport(5);
        const before = s.exportRefcount(5);
        try s.recordSend(.{
            .deliver = .{
                .target = .{ .far = .{ .import_position = 7 } },
                .args = &.{.{ .@"struct" = &.{
                    .{ .key = "cap", .value = .{ .reference = .{ .near = .{ .export_position = 5 } } } },
                } }},
                .answer = 1,
            },
        });
        try std.testing.expectEqual(before + 1, s.exportRefcount(5));
    }

    // Inbound (borrowed steady-state path): a far reference introduced inside a
    // struct entry installs its import.
    {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerImport(7);
        const message = model.Message{
            .deliver = .{
                .target = .{ .far = .{ .import_position = 7 } },
                .args = &.{.{ .@"struct" = &.{
                    .{ .key = "cap", .value = .{ .reference = .{ .far = .{ .import_position = 9 } } } },
                } }},
                .answer = 1,
            },
        };
        try std.testing.expect(!s.hasImport(9));
        try s.recordRecvView(model.view.Body.fromOwned(&message));
        try std.testing.expect(s.hasImport(9));
    }
}

test "session validates gc export positions and deltas align" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(session.Error.MalformedMessage, s.recordRecv(.{
        .gc_export = .{
            .positions = &.{ 3, 7 },
            .deltas = &.{1},
        },
    }));
}

test "releaseUnsharedExport rolls back a freshly allocated export" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    const first = try s.allocateExport();
    const second = try s.allocateExport();
    try std.testing.expect(s.hasExport(first));
    try std.testing.expect(s.hasExport(second));

    s.releaseUnsharedExport(second);
    try std.testing.expect(s.hasExport(first));
    try std.testing.expect(!s.hasExport(second));

    // Ids are monotonic and never reused: the next allocation moves past the
    // released id rather than handing it out again.
    const third = try s.allocateExport();
    try std.testing.expect(third != second);
    try std.testing.expect(third > second);
}

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

fn startSessionMessage(version: model.CaptpVersion) model.Message {
    return .{
        .start_session = .{
            .captp_version = version,
            .session_pubkey = .{ .bytes = &.{ 0xaa, 0xbb } },
            .acceptable_location = .{
                .transport = "memory",
                .designator = "peer",
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &.{0xcc} },
        },
    };
}

test "start-session handshake transitions to open and installs bootstrap export" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    // Local half first: stays negotiating until the partner's half lands.
    try s.recordSend(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.negotiating, s.state);
    try std.testing.expect(!s.handshakeComplete());
    try std.testing.expect(!s.hasExport(session.BOOTSTRAP_POSITION));

    // Partner half completes the handshake → open + bootstrap export@0.
    try s.recordRecv(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.open, s.state);
    try std.testing.expect(s.handshakeComplete());
    try std.testing.expect(s.hasExport(session.BOOTSTRAP_POSITION));
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
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(7);
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
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
        .wire_profile = model.WireProfile.v1_0,
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
        .wire_profile = model.WireProfile.v1_0,
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
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try std.testing.expectError(
        session.Error.CaptpVersionMismatch,
        s.recordRecv(startSessionMessage(.pre_spec)),
    );
}

test "outbound start-session with a mismatched captp version is rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .negotiating = true,
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try std.testing.expectError(
        session.Error.CaptpVersionMismatch,
        s.recordSend(startSessionMessage(.pre_spec)),
    );
    try std.testing.expect(!s.handshake_local_sent);
    try std.testing.expectEqual(session.State.negotiating, s.state);
}

test "session stores selected wire profile and negotiated features" {
    const features = model.FeatureSet{
        .pipelining = true,
        .handoff = false,
        .wire_delta = true,
        .sturdyref = false,
        .stream = false,
        .equality = true,
    };
    var s = session.Session.initWith(std.testing.allocator, .{
        .wire_profile = model.WireProfile.v1_0,
        .features = features,
    });
    defer s.deinit();

    try std.testing.expectEqual(model.CaptpVersion.v1_0, s.wire_profile.captp_version);
    try std.testing.expect(s.needsV1_0Translation());
    try std.testing.expect(s.features.pipelining);
    try std.testing.expect(s.features.wire_delta);
    try std.testing.expect(!s.features.handoff);
}

test "session rejects unknown references at authority boundary" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{},
            .answer = null,
        },
    }));

    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 9 } },
            .args = &.{},
            .answer = null,
        },
    }));
}

test "validate then apply prevents invalid send from installing answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{},
            .answer = 42,
        },
    }));

    try std.testing.expect(s.outboundAnswer(42) == null);
}

test "wire-delta GC decrements export and import refcounts by direction" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(3);
    try s.registerExport(7);
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(3));
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(7));

    // Outbound op:gc-exports releases our refs to the partner's exports →
    // decrements the import table. Inbound op:gc-exports is the partner
    // releasing refs to our exports → decrements the export table.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{1} } });
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{1} } });

    try std.testing.expect(!s.hasImport(3));
    try std.testing.expect(!s.hasExport(7));
}

test "wire-delta GC underflow is a loud error and leaves refcounts intact" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(5);

    // Delta exceeds the live count → rejected, and the count is unchanged.
    try std.testing.expectError(session.Error.GcUnderflow, s.recordRecv(.{
        .gc_export = .{ .positions = &.{5}, .deltas = &.{2} },
    }));
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(5));

    // Unknown id → rejected.
    try std.testing.expectError(session.Error.GcUnderflow, s.recordSend(.{
        .gc_export = .{ .positions = &.{99}, .deltas = &.{1} },
    }));
}

test "re-sending an export retains its wire-delta so a matching gc-exports does not underflow" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(7));

    // Introduce export 7 to the partner twice (two distinct outbound delivers,
    // export 7 named as an argument each time). Each wire crossing must retain.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = session.BOOTSTRAP_POSITION } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = 7 } } }},
        .answer = 1,
    } });
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = session.BOOTSTRAP_POSITION } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = 7 } } }},
        .answer = 2,
    } });
    // Local baseline (1) plus the two wire references the partner now holds.
    try std.testing.expectEqual(@as(u64, 3), s.exportRefcount(7));

    // A conformant partner that received export 7 twice releases with delta 2.
    // It must decrement cleanly — never underflow — and the export survives at
    // its local baseline for re-export.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{2} } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(7));
    try std.testing.expect(s.hasExport(7));
}

test "sending a projection op naming a near receiver retains its wire-delta" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(7));

    // `op:get` / `op:index` / `op:untag` each put export 7 on the wire as the
    // projection receiver, exactly like a deliver target. Each crossing must
    // retain the wire-delta, or the partner's later release underflows.
    try s.recordSend(.{ .get = .{ .receiver = .{ .near = .{ .export_position = 7 } }, .field = "x", .answer = 1 } });
    try s.recordSend(.{ .index = .{ .receiver = .{ .near = .{ .export_position = 7 } }, .index = 0, .answer = 2 } });
    try s.recordSend(.{ .untag = .{ .receiver = .{ .near = .{ .export_position = 7 } }, .tag = "t", .answer = 3 } });
    // Local baseline (1) plus the three wire references the partner now holds.
    try std.testing.expectEqual(@as(u64, 4), s.exportRefcount(7));

    // The partner that received export 7 three times releases with delta 3; it
    // must decrement cleanly down to the local baseline, never underflow.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{3} } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(7));
    try std.testing.expect(s.hasExport(7));
}

// Gift and handoff-count authority lives in the vat-scoped
// `engine.bootstrap.GiftRegistry`; its authority tests live in
// `test/engine/gift_registry_test.zig`. The session keeps only handoff
// well-formedness.
test "session rejects a malformed handoff give" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(session.Error.MalformedMessage, s.recordSend(.{
        .handoff = .{
            .give = .{
                .recipient_key = &.{},
                .exporter_location = "memory:exporter",
                .gifter_exporter_session = &.{},
                .gifter_side = &.{},
                .gift_id = &.{},
                .signature = &.{},
            },
        },
    }));
}

test "session feature gates listen and sturdyref-bearing payloads" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
        .features = model.FeatureSet.minimum(),
    });
    defer s.deinit();
    try s.registerImport(1);
    try s.registerExport(2);

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .listen = .{
            .target = .{ .far = .{ .import_position = 1 } },
            .listener = .{ .near = .{ .export_position = 2 } },
            .wants_partial = false,
        },
    }));

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 1 } },
            .args = &.{.{ .reference = .{ .sturdy = .{
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

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .handoff = .{
            .give = .{
                .recipient_key = &.{},
                .exporter_location = "memory:exporter",
                .gifter_exporter_session = &.{},
                .gifter_side = &.{},
                .gift_id = &.{},
                .signature = &.{},
            },
        },
    }));
}

test "v1.0 session records and queries resolver-callback links" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try std.testing.expect(s.needsV1_0Translation());

    // Outbound: our answer 42 resolves via our local resolver export 7.
    try s.installOutboundResolver(42, 7);
    try std.testing.expectEqual(@as(?u64, 42), s.answerForResolverExport(7));
    try std.testing.expectEqual(@as(?u64, null), s.answerForResolverExport(8));

    // Inbound: the partner's answer 99 resolves via their resolver import 3.
    try s.installInboundResolver(99, 3);
    try std.testing.expectEqual(@as(?u64, 3), s.resolverForInboundAnswer(99));
    try std.testing.expectEqual(@as(?u64, null), s.resolverForInboundAnswer(100));
}

test "v1.0 borrowed inbound raw resolve is rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(7);
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = 7 } },
        .args = &.{},
        .answer = 11,
    } });
    const message = model.Message{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } };
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecvView(model.view.Body.fromOwned(&message)));
}

test "pipelining substrate owns queued calls, listeners, and stored resolution" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // A pending inbound answer (#5), created via an inbound deliver to our
    // export 1 (post-flip `.near`). Export 1 hosts the deliver target; import 1
    // backs the `.far` listener target installed below.
    try s.registerExport(1);
    try s.registerImport(1);
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 1 } },
        .args = &.{},
        .answer = 5,
    } });
    try std.testing.expect(!s.answerResolved(5));

    // Queue two pipelined calls; the session takes ownership of each.
    try s.enqueuePipelinedCall(5, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "a") } });
    try s.enqueuePipelinedCall(5, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "b") } });

    // Queueing against an unknown answer is rejected and frees the message
    // (the testing allocator would flag a leak otherwise).
    try std.testing.expectError(error.InvalidReference, s.enqueuePipelinedCall(
        99,
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "z") } },
    ));

    // A listener (POD target) and a stored resolution.
    try s.installListener(5, .{ .target = .{ .far = .{ .import_position = 1 } }, .wants_partial = false });
    try s.storeResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } });
    try std.testing.expect(s.answerResolved(5));
    const peeked = s.peekResolution(5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(peeked.* == .fulfill);

    // Drain transfers ownership of the queued calls to the caller; a second
    // drain is empty.
    const drained = try s.takePipelinedCalls(5);
    defer {
        for (drained) |message| model.freeMessage(allocator, message);
        allocator.free(drained);
    }
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    const empty = try s.takePipelinedCalls(5);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Draining listeners likewise transfers ownership of each entry's target;
    // a second drain is empty.
    const listeners = try s.takePipelinedListeners(5);
    defer {
        for (listeners) |entry| model.freeReference(allocator, entry.target);
        allocator.free(listeners);
    }
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(usize, 0), (try s.takePipelinedListeners(5)).len);
}

test "pipelining caps fail loud rather than silently dropping" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .queue_cap = 2, .max_listeners_per_target = 1 },
    });
    defer s.deinit();

    // Export 1 hosts the inbound deliver target (post-flip `.near`); import 1
    // backs the `.far` listener target.
    try s.registerExport(1);
    try s.registerImport(1);
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 1 } },
        .args = &.{},
        .answer = 7,
    } });

    try s.enqueuePipelinedCall(7, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "1") } });
    try s.enqueuePipelinedCall(7, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "2") } });
    try std.testing.expectError(error.QueueCapExceeded, s.enqueuePipelinedCall(
        7,
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "3") } },
    ));

    try s.installListener(7, .{ .target = .{ .far = .{ .import_position = 1 } }, .wants_partial = false });
    try std.testing.expectError(error.ListenerCapExceeded, s.installListener(
        7,
        .{ .target = .{ .far = .{ .import_position = 1 } }, .wants_partial = false },
    ));
}

test "imported-promise substrate owns host, listeners, and relayed resolution" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Root import 5 at a third-party host; idempotent for the same host.
    try s.installThirdPartyImport(5, "host-a");
    try std.testing.expect(s.isThirdPartyImport(5));
    try std.testing.expect(!s.isThirdPartyImport(6));
    try s.installThirdPartyImport(5, "host-a");

    // Re-rooting at a different host is a loud error.
    try std.testing.expectError(error.HostMismatch, s.installThirdPartyImport(5, "host-b"));

    // A listener (POD far target) and a stored relayed resolution.
    try s.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_position = 9 } }, .wants_partial = false });
    try s.recordRelayedResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } });
    const peeked = s.importedPromiseResolution(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("v", peeked.fulfill.bytes);

    // recordRelayedResolution overwrites and frees the prior (no leak).
    try s.recordRelayedResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "w") } });
    try std.testing.expectEqualStrings("w", s.importedPromiseResolution(5).?.fulfill.bytes);

    // Recording on an unknown import frees the resolution and errors.
    try std.testing.expectError(error.InvalidReference, s.recordRelayedResolution(
        99,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "z") } },
    ));

    // Drain transfers ownership of each listener target; a second drain is empty.
    const listeners = try s.takeImportedPromiseListeners(5);
    defer {
        for (listeners) |entry| model.freeReference(allocator, entry.target);
        allocator.free(listeners);
    }
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(usize, 0), (try s.takeImportedPromiseListeners(5)).len);
}

test "imported-promise listener cap fails loud" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_listeners_per_target = 1 },
    });
    defer s.deinit();

    try s.installThirdPartyImport(5, "h");
    try s.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_position = 9 } }, .wants_partial = false });
    try std.testing.expectError(error.ListenerCapExceeded, s.installImportedPromiseListener(
        5,
        .{ .target = .{ .far = .{ .import_position = 9 } }, .wants_partial = false },
    ));
    // A listener on an unknown (non-third-party) import errors.
    try std.testing.expectError(error.InvalidReference, s.installImportedPromiseListener(
        99,
        .{ .target = .{ .far = .{ .import_position = 9 } }, .wants_partial = false },
    ));
}

test "outbound gc-export releasing a third-party import drops its imported-promise row" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.installThirdPartyImport(5, "h");
    try s.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_position = 9 } }, .wants_partial = false });
    try s.recordRelayedResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } });
    try std.testing.expect(s.isThirdPartyImport(5));

    // Outbound op:gc-exports releasing import 5 (count 1 → 0) evicts the row,
    // freeing the host designator, the listener target, and the stored resolution.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });
    try std.testing.expect(!s.isThirdPartyImport(5));
    try std.testing.expect(s.importedPromiseResolution(5) == null);
}

test "requeue moves pipelined calls to a new target and detects cycles" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Two pending inbound answers: 1 (resolves to a promise on 2) and 2.
    // Both arrive as inbound delivers to our export 1 (post-flip `.near`).
    try s.registerExport(1);
    inline for (.{ 1, 2 }) |answer| {
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = 1 } },
            .args = &.{},
            .answer = answer,
        } });
    }

    // A call pipelined against answer 1.
    try s.enqueuePipelinedCall(1, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "call") } });

    // Answer 1 resolved to promise(2): drain 1's calls and requeue onto 2, with
    // 1 on the seen chain. 2 is not seen, so this succeeds and 2 owns the call.
    const drained = try s.takePipelinedCalls(1);
    try s.requeuePipelinedCalls(2, &.{1}, drained);

    // A cycle: answer 2 resolves back to promise(1), but 1 is already on the
    // chain — requeue fails loudly and frees the batch (no leak).
    const drained2 = try s.takePipelinedCalls(2);
    try std.testing.expectError(error.ResolutionCycle, s.requeuePipelinedCalls(1, &.{ 1, 2 }, drained2));
}

test "pre-spec session needs no v1.0 resolver translation" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
    });
    defer s.deinit();
    try std.testing.expect(!s.needsV1_0Translation());
}

test "gc-answers prunes the outbound resolver link when the answer is released" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(7);

    // Send a question (answer 5) and commit its resolver export, as the runtime
    // does when augmenting the outbound deliver.
    try s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 5,
        },
    });
    try s.installOutboundResolver(5, 1);
    try std.testing.expectEqual(@as(?u64, 5), s.answerForResolverExport(1));

    // We allocated the question, so we are the side that GCs it: sending
    // `op:gc-answers` for our own answer-pos releases the outbound answer and
    // prunes the resolver link alongside it (CapTP spec § op:gc-answers).
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{5} } });
    try std.testing.expectEqual(@as(?u64, null), s.answerForResolverExport(1));
}

test "import registration is bounded by max_imports (ADR-0025)" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_imports = 2 },
    });
    defer s.deinit();

    try s.registerImport(1);
    try s.registerImport(2);
    // Re-registering a held id is idempotent and never trips the cap.
    try s.registerImport(1);
    // A third *new* import overflows the table.
    try std.testing.expectError(session.Error.ImportCapExceeded, s.registerImport(3));
    try std.testing.expect(!s.hasImport(3));
}

test "inbound resolve whose fulfill names an unheld near export is rejected like a deliver arg" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
    });
    defer s.deinit();
    try s.registerImport(5);

    // We make an outbound call (answer 11) so the partner can resolve it.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = 5 } },
        .args = &.{},
        .answer = 11,
    } });

    // The partner resolves answer 11 with a payload referencing near export 99,
    // which we do not hold. The same near in a deliver arg is rejected, so the
    // fulfill payload must be too — both share one argument-reference contract.
    // Proven on the borrowed steady-state path and the owned retain path alike.
    const bad = model.Message{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = 99 } } } },
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&bad)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(bad));

    // The same resolve naming a near export we do hold is accepted — the rule
    // rejects only unheld references, it does not refuse every near.
    try s.registerExport(99);
    const good = model.Message{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = 99 } } } },
    } };
    try s.recordRecvView(model.view.Body.fromOwned(&good));
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, s.outboundAnswer(11).?.status);
}

test "inbound answers are bounded by max_inbound_answers (ADR-0025)" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_inbound_answers = 2 },
    });
    defer s.deinit();
    try s.registerExport(1);

    inline for (.{ 10, 11 }) |answer| {
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = 1 } },
            .args = &.{},
            .answer = answer,
        } });
    }
    // A third partner-named answer row overflows the table — a loud typed
    // refusal that projects to a resource_exhausted abort, never a silent drop.
    try std.testing.expectError(session.Error.InboundAnswerCapExceeded, s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = 1 } },
            .args = &.{},
            .answer = 12,
        },
    }));
    try std.testing.expect(s.inboundAnswer(12) == null);
}

test "an inbound answer-pos in the reserved virtual range is refused on both recv paths" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(1);

    // Answer positions are partner-named, so the virtual namespace the session
    // allocates from (V1.0 resolver-only fetches) is only collision-free
    // because the partner is refused that range here.
    const message = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = 1 } },
        .args = &.{},
        .answer = session.VIRTUAL_INBOUND_ANSWER_BASE,
    } };
    try std.testing.expectError(
        session.Error.InvalidReference,
        s.recordRecvView(model.view.Body.fromOwned(&message)),
    );
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(message));

    // The session's own virtual allocator hands out exactly that range.
    try std.testing.expect(s.allocateInboundAnswer() >= session.VIRTUAL_INBOUND_ANSWER_BASE);

    // The position just below the base is an ordinary partner choice.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 1 } },
        .args = &.{},
        .answer = session.VIRTUAL_INBOUND_ANSWER_BASE - 1,
    } });
}

test "inbound gc-exports naming the pinned bootstrap position is a no-op" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.transitionToOpen(); // installs the bootstrap export at position 0
    try s.registerExport(7);

    // A partner that accounted its bootstrap import (Goblins installs import 0
    // with a gc will-handler) may release it. Position 0 is pinned outside
    // wire-delta accounting, so the release is skipped — it neither kills the
    // bootstrap export nor underflows.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{0}, .deltas = &.{1} } });
    try std.testing.expect(s.hasExport(session.BOOTSTRAP_POSITION));

    // A later bootstrap fetch still has its target.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = session.BOOTSTRAP_POSITION } },
        .args = &.{ .{ .symbol = "fetch" }, .{ .bytes = "swiss" } },
        .answer = 1,
    } });

    // Skipping position 0 does not skip its neighbors in the same message.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{ 0, 7 }, .deltas = &.{ 5, 1 } } });
    try std.testing.expect(s.hasExport(session.BOOTSTRAP_POSITION));
    try std.testing.expect(!s.hasExport(7));
}

test "mentioning the bootstrap export then receiving its gc never underflows" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.transitionToOpen();
    try s.registerImport(3);

    // Mention our bootstrap export as a deliver argument: `retainSentExports`
    // deliberately never counts position 0, so the partner's accounting and
    // ours disagree about wire references to it — which is exactly why an
    // inbound release of position 0 must be a pinned no-op, never arithmetic.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = 3 } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = session.BOOTSTRAP_POSITION } } }},
        .answer = 1,
    } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(session.BOOTSTRAP_POSITION));

    // The partner received the bootstrap mention and releases with its own
    // delta. No underflow, no spurious abort, bootstrap intact.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{0}, .deltas = &.{2} } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(session.BOOTSTRAP_POSITION));
}

test "outbound gc-exports naming the partner bootstrap is refused" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Our import 0 is the partner's pinned bootstrap — reachable without a
    // table row and outside wire-delta accounting. Releasing it is releasing
    // an id the table never holds, refused before it can reach the wire (a
    // partner that does account it would tear down its bootstrap on receipt).
    try std.testing.expectError(session.Error.GcUnderflow, s.recordSend(.{
        .gc_export = .{ .positions = &.{0}, .deltas = &.{1} },
    }));
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
    // the handshake. The owned path used to skip both — the regression guard.
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

test "gc validation scratch reports host OOM as itself, not GcUnderflow" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 7 } },
        .args = &.{},
        .answer = 11,
    } });

    // The scratch maps inside the gc validators allocate; that failure is a
    // host condition, not a partner protocol violation, and must surface as
    // OutOfMemory (no abort) rather than a spurious GcUnderflow abort.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, session.checkGcExportDecrement(
        failing.allocator(),
        &s.exports,
        .{ .positions = &.{7}, .deltas = &.{1} },
    ));
    var failing_answers = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, session.checkGcAnswerDecrement(
        failing_answers.allocator(),
        &s.inbound_answers,
        &.{11},
    ));
}

test "a second outbound resolve for a settled inbound answer is refused" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 7 } },
        .args = &.{},
        .answer = 11,
    } });

    try s.recordSend(.{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    // An answer resolves exactly once on the send side too, symmetric with the
    // inbound double-resolve rejection: a second resolve would put our own
    // protocol violation on the wire. `recordSend` consumes a resolve's
    // resolution (it transfers into the answer store on success, is freed on
    // refusal), so the break reason is heap-owned here exactly as the engine
    // hands it — the refusal frees it, no leak.
    const again = try allocator.dupe(u8, "again");
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{
        .resolve = .{
            .answer = 11,
            .resolution = .{ .@"break" = .{ .message = again } },
        },
    }));
    // An unknown answer stays the reference error it always was.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .resolve = .{
            .answer = 99,
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    }));
}

test "the import cap is decided in validate, so a refused deliver commits nothing" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_imports = 2 },
    });
    defer s.deinit();
    try s.registerExport(7);
    try s.registerImport(1);

    // Two fresh introductions against one free slot: refused during the
    // validate walk, before apply installs the answer row or either import —
    // the all-or-nothing contract in apply.zig, proven rather than narrated.
    const over = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = 7 } },
        .args = &.{
            .{ .reference = .{ .far = .{ .import_position = 8 } } },
            .{ .reference = .{ .far = .{ .import_position = 9 } } },
        },
        .answer = 11,
    } };
    try std.testing.expectError(
        session.Error.ImportCapExceeded,
        s.recordRecvView(model.view.Body.fromOwned(&over)),
    );
    try std.testing.expectError(session.Error.ImportCapExceeded, s.recordRecv(over));
    try std.testing.expect(s.inboundAnswer(11) == null);
    try std.testing.expect(!s.hasImport(8));
    try std.testing.expect(!s.hasImport(9));

    // One new import repeated twice counts once — the second mention is a
    // refcount refresh, exactly as `registerImport` treats it in apply.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 7 } },
        .args = &.{
            .{ .reference = .{ .far = .{ .import_position = 8 } } },
            .{ .reference = .{ .far = .{ .import_position = 8 } } },
        },
        .answer = 12,
    } });
    try std.testing.expect(s.hasImport(8));
    try std.testing.expectEqual(@as(u64, 2), s.importRefcount(8));
}

test "the import cap on a resolve fulfill payload is decided in validate" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
        .limits = .{ .max_imports = 1 },
    });
    defer s.deinit();
    try s.registerImport(5);

    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = 5 } },
        .args = &.{},
        .answer = 11,
    } });

    // The fulfill introduces a new import past the cap: refused in validate,
    // so the answer is still pending and the import was never installed.
    const over = model.Message{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = 9 } } } },
    } };
    try std.testing.expectError(
        session.Error.ImportCapExceeded,
        s.recordRecvView(model.view.Body.fromOwned(&over)),
    );
    try std.testing.expect(!s.hasImport(9));
    try std.testing.expectEqual(session.AnswerStatus.pending, s.outboundAnswer(11).?.status);
}

test "a partner may reuse an answer position after releasing it" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(7);

    // First life of answer-pos 11: install, resolve, release through
    // op:gc-answers. The row and everything hanging off it die together.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 7 } },
        .args = &.{},
        .answer = 11,
    } });
    try s.recordSend(.{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{11} } });
    try std.testing.expect(s.inboundAnswer(11) == null);

    // The spec lets the partner reuse the position once it is GC'd: the second
    // life lands on a cleared table, indistinguishable from a fresh position.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = 7 } },
        .args = &.{},
        .answer = 11,
    } });
    try std.testing.expectEqual(session.AnswerStatus.pending, s.inboundAnswer(11).?.status);
}
