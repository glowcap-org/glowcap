const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const session = pancake.session;

test "open session accepts outbound deliver to a registered import" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(7);
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
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
    // No registerImport(BOOTSTRAP_EXPORT_ID): the partner bootstrap (import 0) is
    // always reachable on an open session — the bootstrap-fetch send target.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
            .args = &.{ .{ .symbol = "fetch" }, .{ .bytes = "swiss" } },
            .answer = 1,
        },
    };
    try s.recordSend(message);

    // Any other unheld import is still a loud authority error.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
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
            .target = .{ .far = .{ .import_id = 7 } },
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
            .target = .{ .near = .{ .export_id = 7 } },
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
            .target = .{ .near = .{ .export_id = 7 } },
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
    // `<desc:export 7>` decodes to `.near{export_id=7}` in our perspective.
    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_id = 7 } },
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
            .target = .{ .far = .{ .import_id = 7 } },
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
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{.{ .bytes = "x" }},
            .answer = 1,
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&message));
    try std.testing.expect(s.inboundAnswer(1) != null);
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

test "session lifecycle includes negotiating open draining and closed" {
    const allocator = std.testing.allocator;
    var s = session.Session.initNegotiating(allocator);
    defer s.deinit();
    try std.testing.expectEqual(session.State.negotiating, s.state);

    s.open();
    try std.testing.expectEqual(session.State.open, s.state);

    s.beginDrain();
    try std.testing.expectEqual(session.State.draining, s.state);

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
    try std.testing.expect(!s.hasExport(session.BOOTSTRAP_EXPORT_ID));

    // Partner half completes the handshake → open + bootstrap export@0.
    try s.recordRecv(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.open, s.state);
    try std.testing.expect(s.handshakeComplete());
    try std.testing.expect(s.hasExport(session.BOOTSTRAP_EXPORT_ID));
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
            .target = .{ .far = .{ .import_id = 7 } },
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
    try std.testing.expect(s.wire_profile.flags.goblins_canonical);
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
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{},
            .answer = null,
        },
    }));

    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 9 } },
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
            .target = .{ .far = .{ .import_id = 7 } },
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
        .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
        .args = &.{.{ .reference = .{ .near = .{ .export_id = 7 } } }},
        .answer = 1,
    } });
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
        .args = &.{.{ .reference = .{ .near = .{ .export_id = 7 } } }},
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

fn makeReceive(
    gift_id: []const u8,
    recipient_key: []const u8,
    session_id: []const u8,
    count: u64,
) model.HandoffReceive {
    return .{
        .receiving_session = session_id,
        .receiving_side = "recipient-side",
        .handoff_count = count,
        .signed_give = .{
            .recipient_key = recipient_key,
            .exporter_location = "memory:exporter",
            .gifter_exporter_session = "gifter-session",
            .gifter_side = "gifter-side",
            .gift_id = gift_id,
            .signature = &.{},
        },
        .signature = &.{},
    };
}

test "exporter deposits a gift and accepts a matching withdrawal" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.depositGift("gift-1", "recipient-key", "");
    try std.testing.expect(s.giftDeposited("gift-1"));
    try std.testing.expect(!s.giftWithdrawn("gift-1"));

    try s.recordRecv(.{ .handoff = .{ .receive = makeReceive("gift-1", "recipient-key", "session-a", 1) } });
    try std.testing.expect(s.giftWithdrawn("gift-1"));
}

test "exporter rejects withdrawal of an unknown gift" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(
        session.Error.InvalidGift,
        s.recordRecv(.{ .handoff = .{ .receive = makeReceive("ghost-gift", "recipient-key", "session-a", 1) } }),
    );
}

test "exporter rejects withdrawal with a mismatched recipient key" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.depositGift("gift-1", "recipient-key", "");

    try std.testing.expectError(
        session.Error.InvalidGift,
        s.recordRecv(.{ .handoff = .{ .receive = makeReceive("gift-1", "imposter-key", "session-a", 1) } }),
    );
    try std.testing.expect(!s.giftWithdrawn("gift-1"));
}

test "exporter rejects a replayed or out-of-order handoff count" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.depositGift("gift-1", "recipient-key", "");
    try s.depositGift("gift-2", "recipient-key", "");

    try s.recordRecv(.{ .handoff = .{ .receive = makeReceive("gift-1", "recipient-key", "session-a", 2) } });

    try std.testing.expectError(
        session.Error.HandoffReplay,
        s.recordRecv(.{ .handoff = .{ .receive = makeReceive("gift-2", "recipient-key", "session-a", 1) } }),
    );
    try std.testing.expect(!s.giftWithdrawn("gift-2"));
}

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
            .target = .{ .far = .{ .import_id = 1 } },
            .listener = .{ .near = .{ .export_id = 2 } },
            .wants_partial = false,
        },
    }));

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 1 } },
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
        .target = .{ .near = .{ .export_id = 1 } },
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
    try s.installListener(5, .{ .target = .{ .far = .{ .import_id = 1 } }, .wants_partial = false });
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
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.queue_cap = 2;
    s.limits.max_listeners_per_target = 1;

    // Export 1 hosts the inbound deliver target (post-flip `.near`); import 1
    // backs the `.far` listener target.
    try s.registerExport(1);
    try s.registerImport(1);
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_id = 1 } },
        .args = &.{},
        .answer = 7,
    } });

    try s.enqueuePipelinedCall(7, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "1") } });
    try s.enqueuePipelinedCall(7, .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "2") } });
    try std.testing.expectError(error.QueueCapExceeded, s.enqueuePipelinedCall(
        7,
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "3") } },
    ));

    try s.installListener(7, .{ .target = .{ .far = .{ .import_id = 1 } }, .wants_partial = false });
    try std.testing.expectError(error.ListenerCapExceeded, s.installListener(
        7,
        .{ .target = .{ .far = .{ .import_id = 1 } }, .wants_partial = false },
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
    try s.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_id = 9 } }, .wants_partial = false });
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
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_listeners_per_target = 1;

    try s.installThirdPartyImport(5, "h");
    try s.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_id = 9 } }, .wants_partial = false });
    try std.testing.expectError(error.ListenerCapExceeded, s.installImportedPromiseListener(
        5,
        .{ .target = .{ .far = .{ .import_id = 9 } }, .wants_partial = false },
    ));
    // A listener on an unknown (non-third-party) import errors.
    try std.testing.expectError(error.InvalidReference, s.installImportedPromiseListener(
        99,
        .{ .target = .{ .far = .{ .import_id = 9 } }, .wants_partial = false },
    ));
}

test "outbound gc-export releasing a third-party import drops its imported-promise row" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.installThirdPartyImport(5, "h");
    try s.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_id = 9 } }, .wants_partial = false });
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
            .target = .{ .near = .{ .export_id = 1 } },
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
    var s = session.Session.init(allocator);
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
            .target = .{ .far = .{ .import_id = 7 } },
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
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_imports = 2;

    try s.registerImport(1);
    try s.registerImport(2);
    // Re-registering a held id is idempotent and never trips the cap.
    try s.registerImport(1);
    // A third *new* import overflows the table.
    try std.testing.expectError(session.Error.ImportCapExceeded, s.registerImport(3));
    try std.testing.expect(!s.hasImport(3));
}

test "deposited gifts are bounded by max_deposited_gifts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    s.limits.max_deposited_gifts = 1;

    try s.depositGift("gift-a", "recipient", "");
    try std.testing.expectError(
        session.Error.DepositedGiftCapExceeded,
        s.depositGift("gift-b", "recipient", ""),
    );
    try std.testing.expect(s.giftDeposited("gift-a"));
    try std.testing.expect(!s.giftDeposited("gift-b"));
}

test "seen-handoff-count rows are bounded by max_seen_handoff_counts (ADR-0025)" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    s.limits.max_seen_handoff_counts = 1;

    // Two gifts so two distinct receiving sessions can withdraw.
    try s.depositGift("gift-a", "recipient", "");
    try s.depositGift("gift-b", "recipient", "");

    const withdraw = struct {
        fn make(gift_id: []const u8, receiving_session: []const u8, count: u64) model.Message {
            return .{ .handoff = .{ .receive = .{
                .receiving_session = receiving_session,
                .receiving_side = "side",
                .handoff_count = count,
                .signed_give = .{
                    .recipient_key = "recipient",
                    .exporter_location = "memory:exporter",
                    .gifter_exporter_session = &.{},
                    .gifter_side = &.{},
                    .gift_id = gift_id,
                    .signature = &.{},
                },
                .signature = &.{},
            } } };
        }
    };

    // First receiving session records a row.
    try s.recordRecv(withdraw.make("gift-a", "session-1", 1));
    // A second distinct receiving session overflows the replay-tracking table.
    try std.testing.expectError(
        session.Error.HandoffCountCapExceeded,
        s.recordRecv(withdraw.make("gift-b", "session-2", 1)),
    );
}

test "inbound resolve whose fulfill names an unheld near export is rejected like a deliver arg" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(5);

    // We make an outbound call (answer 11) so the partner can resolve it.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = 5 } },
        .args = &.{},
        .answer = 11,
    } });

    // The partner resolves answer 11 with a payload referencing near export 99,
    // which we do not hold. The same near in a deliver arg is rejected, so the
    // fulfill payload must be too — both share one argument-reference contract.
    // Proven on the borrowed steady-state path and the owned retain path alike.
    const bad = model.Message{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_id = 99 } } } },
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&bad)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(bad));

    // The same resolve naming a near export we do hold is accepted — the rule
    // rejects only unheld references, it does not refuse every near.
    try s.registerExport(99);
    const good = model.Message{ .resolve = .{
        .answer = 11,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_id = 99 } } } },
    } };
    try s.recordRecvView(model.view.Body.fromOwned(&good));
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, s.outboundAnswer(11).?.status);
}
