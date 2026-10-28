//! The answer tables: recording and settling, refusing an unheld far in a
//! fulfill, validate-before-apply, bounded inbound answers over the complete
//! u64 namespace, wire answers never aliasing private local promises,
//! position reuse only after release, and an answer descriptor naming a live
//! question in the asker's table on every message that carries one.

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
    // has no row yet is how the application exports that object for the first status-allow: pending state or quoted runtime label
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

test "CapTP 1.0 reuses a released pending question with a fresh identity" {
    var s = session.Session.initWith(std.testing.allocator, .{ .captp_version = .v1_0 });
    defer s.deinit();

    const first = try s.allocateOutboundAnswer();
    try s.installOutboundAnswer(first.position);
    try s.releaseOutboundAnswer(first.position);
    try std.testing.expect(!s.hasLiveOutboundAnswer(first));
    try std.testing.expect(s.outboundAnswerTarget(first.position) == null);
    try std.testing.expect(!s.outbound_answers.contains(first.position));

    // Resolver callbacks carry separate export authority, so the next
    // question reuses the slot with a new identity.
    const second = try s.allocateOutboundAnswer();
    try std.testing.expectEqual(first.position, second.position);
    try std.testing.expect(first.row_id != second.row_id);
    try std.testing.expectEqual(@as(u64, 0), s.outbound_answers.count(first.position));
}

test "a desc:answer names a live question in the asker's table on every carrier" {
    const allocator = std.testing.allocator;
    // The asker is the sender of a call and the receiver of a resolution, so
    // the same descriptor is checked against the partner's questions in a
    // deliver's arguments and against ours in a resolve's payload. A position
    // with no live row is refused in every position it can appear, because an
    // unknown one would alias the next question asked at that number.
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer s.deinit();
    try s.registerImport(.from(3));
    const partner = model.Reference{ .far = .{ .import_position = .from(3) } };
    const bootstrap = model.Reference{ .near = .{ .export_position = .from(0) } };
    // A question the partner asked (41) and one we asked (5).
    try s.recordRecv(.{ .deliver = .{
        .target = bootstrap,
        .args = &.{},
        .answer = .from(41),
        .resolve_me_desc = .{ .far = model.FarRef.object(8) },
    } });
    try s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{}, .answer = .from(5) } });

    // In a received call, a `desc:answer` is the partner's question.
    const asked = model.Argument{ .reference = .{ .promise = .{ .answer_position = .from(41) } } };
    const never_asked = model.Argument{ .reference = .{ .promise = .{ .answer_position = .from(42) } } };
    try s.recordRecv(.{ .deliver = .{ .target = bootstrap, .args = &.{asked} } });
    try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .deliver = .{
        .target = bootstrap,
        .args = &.{never_asked},
    } }));
    // Nested inside a list, the same rule.
    try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .deliver = .{
        .target = bootstrap,
        .args = &.{.{ .list = &.{never_asked} }},
    } }));

    // In a received resolution, a `desc:answer` is still the partner's
    // question: the partner may settle 5 with its own pending question 41,
    // never with one we asked or one it never asked.
    try s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{}, .answer = .from(6) } });
    try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .resolve = .{
        .answer = .from(5),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(6) } } } },
    } }));
    try std.testing.expect(s.outboundAnswer(.from(5)).?.status == .pending);
    try s.recordRecv(.{ .resolve = .{
        .answer = .from(5),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(41) } } } },
    } });

    // In a sent call, a `desc:answer` is our question.
    try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .deliver = .{
        .target = partner,
        .args = &.{.{ .reference = .{ .promise = .{ .answer_position = .from(41) } } }},
    } }));
    try s.recordSend(.{ .deliver = .{
        .target = partner,
        .args = &.{.{ .reference = .{ .promise = .{ .answer_position = .from(6) } } }},
    } });
    // A sent resolution admits no answer reference: the question it would
    // name lives at the partner, so nothing here could carry a pipelined call
    // onto it.
    try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .resolve = .{
        .answer = .from(41),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(6) } } } },
    } }));
}

/// A row count of every session table a reference can touch. Equal counts
/// before and after a refused message show the refusal committed nothing.
const TableCounts = struct {
    imports: usize = 0,
    import_refs: u64 = 0,
    exports: usize = 0,
    export_refs: u64 = 0,
    inbound_answers: usize = 0,
    outbound_answers: usize = 0,

    fn of(s: *const session.Session) TableCounts {
        var counts: TableCounts = .{};
        session.inspect.forEachImport(s, &counts, countImport);
        session.inspect.forEachExport(s, &counts, countExport);
        session.inspect.forEachInboundAnswer(s, &counts, countInbound);
        session.inspect.forEachOutboundAnswer(s, &counts, countOutbound);
        return counts;
    }
    fn countImport(self: *TableCounts, view: session.ImportView) void {
        self.imports += 1;
        self.import_refs += view.refcount;
    }
    fn countExport(self: *TableCounts, view: session.ExportView) void {
        self.exports += 1;
        self.export_refs += view.refcount;
    }
    fn countInbound(self: *TableCounts, _: session.AnswerRowView) void {
        self.inbound_answers += 1;
    }
    fn countOutbound(self: *TableCounts, _: session.AnswerRowView) void {
        self.outbound_answers += 1;
    }
};

/// Every nesting a reference can take inside a message's values.
fn shapes(comptime inner: model.Argument) [5]model.Argument {
    const entry = [_]model.StructEntry{.{ .key = "k", .value = inner }};
    const nested_entry = [_]model.StructEntry{.{ .key = "k", .value = .{ .list = &.{inner} } }};
    return .{
        inner,
        .{ .list = &.{inner} },
        .{ .tagged = .{ .tag = "t", .value = &.{inner} } },
        .{ .@"struct" = &entry },
        .{ .tagged = .{ .tag = "t", .value = &.{.{ .@"struct" = &nested_entry }} } },
    };
}

test "a dead reference is refused in every nesting shape on every carrier, committing nothing" {
    const allocator = std.testing.allocator;
    // The validator walks a message's values once, so a position it refuses at
    // the top is refused inside a list, a tagged value, a struct, and a struct
    // inside a tagged value, and in every place a value can ride: a received
    // call's arguments, a received resolution, a sent call's arguments, and a
    // sent resolution. The partner asked question 41 with resolver import 8,
    // we asked question 5, we hold import 3, export 9 is one we have
    // mentioned, and nothing else exists.
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer s.deinit();
    try s.registerImport(.from(3));
    const partner = model.Reference{ .far = .{ .import_position = .from(3) } };
    const bootstrap = model.Reference{ .near = .{ .export_position = .from(0) } };
    try s.recordRecv(.{ .deliver = .{
        .target = bootstrap,
        .args = &.{},
        .answer = .from(41),
        .resolve_me_desc = .{ .far = model.FarRef.object(8) },
    } });
    try s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{}, .answer = .from(5) } });
    try s.registerExport(.from(9));
    const before = TableCounts.of(&s);

    // A question nobody asked, and an export nobody holds.
    const dead_answer = comptime model.Argument{ .reference = .{ .promise = .{ .answer_position = .from(42) } } };
    const unheld_near = comptime model.Argument{ .reference = .{ .near = .{ .export_position = .from(99) } } };
    for (comptime shapes(dead_answer) ++ shapes(unheld_near)) |value| {
        try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .deliver = .{ .target = bootstrap, .args = &.{value} } }));
        try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .resolve = .{ .answer = .from(5), .resolution = .{ .fulfill = value } } }));
        try std.testing.expectEqual(before, TableCounts.of(&s));
    }
    // Sent, a dead answer is refused the same way. A sent `near` is this side's
    // own export and mints its row, so only the answer is dead on this side. A
    // sent resolution is owned by the session, which frees a refused one.
    for (comptime shapes(dead_answer)) |value| {
        try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{value} } }));
        const owned = try model.cloneArgument(allocator, value);
        try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .resolve = .{ .answer = .from(41), .resolution = .{ .fulfill = owned } } }));
        try std.testing.expectEqual(before, TableCounts.of(&s));
    }
    // A refused message that also carries a held export of ours takes no
    // mention for it: the export's count is part of `before`.
    const held_near = comptime model.Argument{ .reference = .{ .near = .{ .export_position = .from(9) } } };
    const both = try model.cloneArgument(allocator, .{ .list = &.{ dead_answer, held_near } });
    try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .resolve = .{ .answer = .from(41), .resolution = .{ .fulfill = both } } }));
    try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{ dead_answer, held_near } } }));
    const unasked = try model.cloneArgument(allocator, held_near);
    try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = unasked } } }));
    try std.testing.expectEqual(before, TableCounts.of(&s));

    // The live rows answer: the partner's question in a received call
    // and a received resolution, ours in a sent call. A sent resolution never
    // names the partner's question, even a live one.
    const theirs = model.Argument{ .reference = .{ .promise = .{ .answer_position = .from(41) } } };
    const ours = model.Argument{ .reference = .{ .promise = .{ .answer_position = .from(5) } } };
    try s.recordRecv(.{ .deliver = .{ .target = bootstrap, .args = &.{.{ .list = &.{theirs} }} } });
    try s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{.{ .list = &.{ours} }} } });
    try s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{}, .answer = .from(6) } });
    try s.recordRecv(.{ .resolve = .{ .answer = .from(5), .resolution = .{ .fulfill = .{ .list = &.{.{ .reference = .{ .promise = .{ .answer_position = .from(41) } } }} } } } });
    try s.recordRecv(.{ .deliver = .{
        .target = bootstrap,
        .args = &.{},
        .answer = .from(43),
        .resolve_me_desc = .{ .far = model.FarRef.object(8) },
    } });
    const settled = try model.cloneArgument(allocator, .{ .list = &.{.{ .reference = .{ .promise = .{ .answer_position = .from(43) } } }} });
    try std.testing.expectError(error.InvalidReference, s.recordSend(.{ .resolve = .{ .answer = .from(41), .resolution = .{ .fulfill = settled } } }));
}
