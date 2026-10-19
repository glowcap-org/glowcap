//! The answer tables: recording and settling, refusing an unheld far in a
//! fulfill, validate-before-apply, bounded inbound answers over the complete
//! u64 namespace, wire answers never aliasing private local promises, and
//! position reuse only after release.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

test "session records inbound answers and settles on resolve" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // Inbound deliver to our export 7. Post-flip (ADR-0006) the wire
    // `<desc:export 7>` decodes to `.near{export_position=7}` in our perspective.
    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(11),
        },
    });
    try std.testing.expect(s.inboundAnswer(.from(11)) != null);

    try s.recordSend(.{
        .resolve = .{
            .answer = .from(11),
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    });

    try std.testing.expectEqual(session.AnswerStatus.fulfilled, s.inboundAnswer(.from(11)).?.status);
}

test "a resolve fulfilling with an unheld far is refused, while a near still exports" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    try s.registerImport(.from(3));

    // Two inbound answers to settle, so each half of the rule gets a pending
    // row of its own.
    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(11),
        },
    });
    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(12),
        },
    });

    // An import position names the partner's export on *this* session and
    // nowhere else. Import 3 is held here; import 4 is not, so a fulfill
    // naming it would put `<desc:export 4>` on the wire for an export this
    // partner never made. A partner that numbers its exports low, as Goblins
    // does, is liable to hold a live, unrelated object at that number, so the
    // reference designates the wrong capability rather than failing. Refuse it
    // here, the same rule the deliver path already holds for its arguments.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .resolve = .{
            .answer = .from(11),
            .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(4) } } } },
        },
    }));
    // Refused pre-commit: the answer is still pending, so the session can
    // settle it properly afterwards.
    try std.testing.expectEqual(session.AnswerStatus.pending, s.inboundAnswer(.from(11)).?.status);

    // The held far is accepted, so the rule refuses the unheld position rather
    // than every far in a fulfill.
    try s.recordSend(.{
        .resolve = .{
            .answer = .from(11),
            .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(3) } } } },
        },
    });

    // The export-on-resolve asymmetry survives: a `near` naming an export that
    // has no row yet is how the application exports that object for the first
    // time, and it is still accepted.
    try s.recordSend(.{
        .resolve = .{
            .answer = .from(12),
            .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(8) } } } },
        },
    });
    try std.testing.expect(s.exports.contains(.from(8)));
}

test "validate then apply prevents invalid send from installing answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(42),
        },
    }));

    try std.testing.expect(s.outboundAnswer(.from(42)) == null);
}

test "answered-send OOM publishes neither answer nor export retain" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var s = session.Session.init(failing.allocator());
    defer {
        failing.fail_index = std.math.maxInt(usize);
        s.deinit();
    }
    try s.registerImport(.from(1));
    try s.registerExport(.from(7));
    const baseline = s.exportRefcount(.from(7));
    const args = [_]model.Argument{.{ .reference = .{
        .near = .{ .export_position = .from(7) },
    } }};

    // The outbound-answer table is the only allocation this send needs. It
    // must be acquired before the near argument takes a wire-delta retain.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &args,
        .answer = .from(42),
    } }));

    try std.testing.expectEqual(baseline, s.exportRefcount(.from(7)));
    try std.testing.expect(s.outboundAnswer(.from(42)) == null);
}

test "inbound resolve whose fulfill names an unheld near export is rejected like a deliver arg" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
    });
    defer s.deinit();
    try s.registerImport(.from(5));

    // We make an outbound call (answer 11) so the partner can resolve it.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(5) } },
        .args = &.{},
        .answer = .from(11),
    } });

    // The partner resolves answer 11 with a payload referencing near export 99,
    // which we do not hold. The same near in a deliver arg is rejected, so the
    // fulfill payload must be too, both share one argument-reference contract.
    // Proven on the borrowed steady-state path and the owned retain path alike.
    const bad = model.Message{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(99) } } } },
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&bad)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(bad));

    // The same resolve naming a near export we do hold is accepted, the rule
    // rejects only unheld references, it does not refuse every near.
    try s.registerExport(.from(99));
    const good = model.Message{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(99) } } } },
    } };
    try s.recordRecvView(model.view.Body.fromOwned(&good));
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, s.outboundAnswer(.from(11)).?.status);
}

test "inbound answers are bounded by max_inbound_answers (ADR-0008)" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_inbound_answers = 2 },
    });
    defer s.deinit();
    try s.registerExport(.from(1));

    inline for (.{ 10, 11 }) |answer| {
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = .from(1) } },
            .args = &.{},
            .answer = .from(answer),
            .resolve_me_desc = .{ .far = model.FarRef.object(0) },
        } });
    }
    // A third partner-named answer row overflows the table, a loud typed
    // refusal that projects to a resource_exhausted abort, never a silent drop.
    try std.testing.expectError(session.Error.InboundAnswerCapExceeded, s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = .from(1) } },
            .args = &.{},
            .answer = .from(12),
        },
    }));
    try std.testing.expect(s.inboundAnswer(.from(12)) == null);
}

test "the complete u64 answer namespace remains available to the partner" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(1));

    // Virtual answers use a distinct type, so neither the former band boundary
    // nor the largest wire position needs to be confiscated.
    const message = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(std.math.maxInt(u64)),
    } };
    try s.recordRecvView(model.view.Body.fromOwned(&message));
    try std.testing.expect(s.inboundAnswer(.from(std.math.maxInt(u64))) != null);

    var owned = session.Session.init(allocator);
    defer owned.deinit();
    try owned.registerExport(.from(1));
    try owned.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(std.math.maxInt(u64)),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });
    try std.testing.expect(owned.inboundAnswer(.from(std.math.maxInt(u64))) != null);
}

test "virtual answer exhaustion returns a typed failure instead of wrapping" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    s.next_virtual_inbound_answer = std.math.maxInt(u64);

    try std.testing.expectEqual(std.math.maxInt(u64), (try s.allocateInboundAnswer()).int());
    try std.testing.expectError(error.VirtualAnswerSpaceExhausted, s.allocateInboundAnswer());
}

test "wire gc-answers cannot alias a private local-promise answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    const projection = try s.allocateLocalPromiseProjection();
    const collision = model.AnswerPosition.from(projection.answer_name.virtual.int());
    try s.registerExport(.from(7));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = collision,
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });
    try std.testing.expect(s.inboundAnswer(collision) != null);
    try std.testing.expect(s.inboundAnswerNamed(projection.answer_name) != null);

    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{collision.int()} } });
    try std.testing.expect(s.inboundAnswer(collision) == null);
    try std.testing.expect(s.inboundAnswerNamed(projection.answer_name) != null);
    try std.testing.expectEqual(
        projection.answer_name,
        s.answerForLocalPromiseExport(projection.export_position).?,
    );
}

test "a projection op accepts every fresh wire answer and refuses reuse" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .captp_version = .v1_0 });
    defer s.deinit();
    try s.registerExport(.from(1));

    // `op:get` / `op:index` / `op:untag` each names an answer of its own. The
    // complete wire namespace is available because virtual answers are typed.
    const receiver = model.Reference{ .near = .{ .export_position = .from(1) } };
    const high = model.AnswerPosition.from(std.math.maxInt(u64));
    const get = model.Message{ .get = .{ .receiver = receiver, .field = "field", .answer = high } };
    try s.recordRecv(get);
    try std.testing.expect(s.inboundAnswer(high) != null);

    // And an answer already naming a live question is not free to reuse.
    const ordinary = model.AnswerPosition.from(7);
    try s.recordRecv(.{ .deliver = .{
        .target = receiver,
        .args = &.{},
        .answer = ordinary,
    } });
    const reuse = model.Message{ .get = .{ .receiver = receiver, .field = "field", .answer = ordinary } };
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecv(reuse));
}

test "a second outbound resolve for a settled inbound answer is refused" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });

    try s.recordSend(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    // An answer resolves exactly once on the send side too, symmetric with the
    // inbound double-resolve rejection: a second resolve would put our own
    // protocol violation on the wire. `recordSend` consumes a resolve's
    // resolution (it transfers into the answer store on success, is freed on
    // refusal), so the break reason is heap-owned here exactly as the engine
    // hands it, the refusal frees it, no leak.
    const again = try allocator.dupe(u8, "again");
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{
        .resolve = .{
            .answer = .from(11),
            .resolution = .{ .@"break" = .{ .message = again } },
        },
    }));
    // An unknown answer stays the reference error it always was.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .resolve = .{
            .answer = .from(99),
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    }));
}

test "a partner may reuse an answer position after releasing it" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // First life of answer-pos 11: install, resolve, release through
    // op:gc-answers. The row and everything hanging off it die together.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });
    try s.recordSend(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{11} } });
    try std.testing.expect(s.inboundAnswer(.from(11)) == null);

    // The spec lets the partner reuse the position once it is GC'd: the second
    // life lands on a cleared table, indistinguishable from a fresh position.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });
    try std.testing.expectEqual(session.AnswerStatus.pending, s.inboundAnswer(.from(11)).?.status);
}

test "a settled question's position is asked again under a new identity" {
    var s = session.Session.initWith(std.testing.allocator, .{ .captp_version = .next });
    defer s.deinit();

    const first = try s.allocateOutboundAnswer();
    try std.testing.expectEqual(first, s.outboundAnswerTarget(first.position).?);
    try s.installOutboundAnswer(first.position);
    try std.testing.expect(s.hasLiveOutboundAnswer(first));

    try s.releaseOutboundAnswer(first.position);
    try std.testing.expect(!s.hasLiveOutboundAnswer(first));
    try std.testing.expect(s.outboundAnswerTarget(first.position) == null);

    // The partner answered and released the position, so it is the next one
    // minted. The question it now names is a different one.
    const second = try s.allocateOutboundAnswer();
    try std.testing.expectEqual(first.position, second.position);
    try std.testing.expect(second.row_id != first.row_id);
    try s.installOutboundAnswer(second.position);
    try std.testing.expect(s.hasLiveOutboundAnswer(second));
    try std.testing.expect(!s.hasLiveOutboundAnswer(first));
    try std.testing.expect(!s.outboundAnswerReleaseClaimed(first));
    try std.testing.expectEqual(second, s.outboundAnswerTarget(first.position).?);
}

test "CapTP 1.0 withholds a pending question's position the partner may still resolve" {
    var s = session.Session.initWith(std.testing.allocator, .{ .captp_version = .v1_0 });
    defer s.deinit();

    const first = try s.allocateOutboundAnswer();
    try s.installOutboundAnswer(first.position);
    try s.releaseOutboundAnswer(first.position);
    try std.testing.expect(!s.hasLiveOutboundAnswer(first));
    try std.testing.expect(s.outboundAnswerTarget(first.position) == null);
    try std.testing.expect(!s.outbound_answers.contains(first.position));

    // The partner's resolve still names this position, so the next question
    // takes the one after it.
    const second = try s.allocateOutboundAnswer();
    try std.testing.expectEqual(first.position.int() + 1, second.position.int());
    try std.testing.expectEqual(@as(u64, 0), s.outbound_answers.count(first.position));
}
