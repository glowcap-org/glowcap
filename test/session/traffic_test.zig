//! What a deliver may carry and name: descriptor roles and answer liveness,
//! nesting depth on both directions, and references crossing every session
//! walk. The duplicate-set and comparison-bound family lives in
//! `set_uniqueness_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

test "open session accepts outbound deliver to a registered import" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    };

    try s.recordSend(message);
}

test "open session accepts an outbound deliver to the partner bootstrap without registering it" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    // No registerImport(BOOTSTRAP_POSITION): the partner bootstrap (import 0) is
    // always reachable on an open session, the bootstrap-fetch send target.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
            .args = &.{ .{ .symbol = "fetch" }, .{ .bytes = "swiss" } },
            .answer = .from(1),
        },
    };
    try s.recordSend(message);

    // Any other unheld import is still a loud authority error.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "x" }},
            .answer = .from(2),
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
    try s.registerImport(.from(7));

    try s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });

    try std.testing.expect(s.outboundAnswer(.from(42)) != null);
    try std.testing.expectEqual(session.AnswerStatus.pending, s.outboundAnswer(.from(42)).?.status);
}

test "outbound deliver targets require the target descriptor role and a live answer" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer s.deinit();
    try s.registerImport(.from(7));
    try s.registerExport(.from(8));

    // A near is one of our exports and would encode as `desc:import-*`, which is
    // never a deliver target. Refuse before apply retains it or installs the
    // answer carried by the invalid deliver.
    const before = s.exportRefcount(.from(8));
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .deliver = .{
        .target = .{ .near = model.NearRef.object(8) },
        .args = &.{},
        .answer = .from(40),
    } }));
    try std.testing.expectEqual(before, s.exportRefcount(.from(8)));
    try std.testing.expect(s.outboundAnswer(.from(40)) == null);

    // Next carries no inline resolver. Refuse it at session validation, before
    // the codec can fail after the answer has already been installed.
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(41),
        .resolve_me_desc = .{ .far = model.FarRef.object(7) },
    } }));
    try std.testing.expect(s.outboundAnswer(.from(41)) == null);

    // `desc:answer` is a role, not an unchecked integer. An unknown answer is
    // refused before the new answer on this deliver can alias session state.
    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(99) } },
        .args = &.{},
        .answer = .from(41),
    } }));
    try std.testing.expect(s.outboundAnswer(.from(41)) == null);

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

test "outbound operations cannot reuse a live answer position" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } });

    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } }));
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordSend(.{ .index = .{
        .receiver = .{ .far = model.FarRef.object(7) },
        .index = .{ .integer = 0 },
        .answer = .from(42),
    } }));
}

test "inbound deliver reusing a live answer position is UnexpectedMessage" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    const first = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(1),
    } };
    try s.recordRecv(first);

    // Same answer still live (pending): a second wire deliver is a protocol
    // violation, refused on recv, not deferred to our outbound resolve.
    const replay = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(1),
    } };
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecv(replay));

    // After we resolve the answer, reuse is still refused until gc-answers.
    try s.recordSend(.{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .fulfill = .{ .integer = 0 } },
    } });
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecv(replay));
}

test "inbound deliver nested past max_nesting_depth fails closed" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

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
    // overflowing the native stack, a one-frame DoS becomes a typed error
    // that the runtime projects to a `resource_exhausted` op:abort.
    try std.testing.expectError(session.Error.NestingTooDeep, s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = .from(7) } },
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
            .target = .{ .near = .{ .export_position = .from(7) } },
            .args = ok_node,
            .answer = null,
        },
    });
}

test "inbound deliver targets enforce descriptor role and answer liveness atomically" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    // Even held import 7 is the wrong role: inbound `.far` decoded from
    // `desc:import-*`, while a deliver target must be `desc:export` (`near`) or
    // `desc:answer` (`promise`). The message also carries an answer and a fresh
    // import introduction; both must remain absent after either recv path
    // refuses the target.
    const introduced = model.Argument{ .reference = .{ .far = model.FarRef.object(9) } };
    const wrong_role = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{introduced},
        .answer = .from(1),
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&wrong_role)));
    try std.testing.expect(s.inboundAnswer(.from(1)) == null);
    try std.testing.expect(!s.hasImport(.from(9)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(wrong_role));
    try std.testing.expect(s.inboundAnswer(.from(1)) == null);
    try std.testing.expect(!s.hasImport(.from(9)));

    // An answer descriptor must name a row the partner opened. As
    // above, refusal is pre-commit on the owned and borrowed paths.
    const dead_answer = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(77) } },
        .args = &.{.{ .reference = .{ .far = model.FarRef.object(10) } }},
        .answer = .from(2),
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&dead_answer)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(dead_answer));
    try std.testing.expect(s.inboundAnswer(.from(2)) == null);
    try std.testing.expect(!s.hasImport(.from(10)));

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
    try s.recordRecv(live_answer);
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{77} } });
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&live_answer)));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(live_answer));
}

test "partner introductions accept the complete u64 import space" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    // The pinned bootstrap export is always a valid inbound `desc:export 0`
    // target, without a table grant.

    const high_far = model.Argument{ .reference = .{ .far = .{ .import_position = .from(std.math.maxInt(u64)) } } };
    const high = model.Message{
        .deliver = .{
            .target = .{ .near = model.NearRef.object(session.BOOTSTRAP_POSITION) },
            .args = &.{high_far},
            .answer = .from(1),
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&high));
    try std.testing.expect(s.hasImport(.from(std.math.maxInt(u64))));

    const old_boundary = model.Argument{ .reference = .{ .far = .{ .import_position = .from(@as(u64, 1) << 60) } } };
    const clean = model.Message{
        .deliver = .{
            .target = .{ .near = model.NearRef.object(session.BOOTSTRAP_POSITION) },
            .args = &.{old_boundary},
            .answer = .from(2),
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&clean));
}

test "a reference inside a Struct argument crosses every session walk" {
    // Struct entries carry full argument values (ADR-0046), so a reference can
    // ride inside one. Every argument walker must recurse through struct
    // entries as well as list/set/tagged, or a struct-wrapped reference dodges
    // outbound validation, introduced-import
    // installation, and sent-export retention.
    const allocator = std.testing.allocator;

    // Outbound: a near reference naming an unregistered export, wrapped in a
    // struct entry, is still an authority error.
    {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerImport(.from(7));
        try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
            .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &.{.{ .@"struct" = &.{
                    .{ .key = "cap", .value = .{ .reference = .{ .near = .{ .export_position = .from(99) } } } },
                } }},
                .answer = .from(1),
            },
        }));
    }

    // Outbound: a held export named through a struct entry is retained, so the
    // partner's later gc-exports delta cannot underflow the table.
    {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerImport(.from(7));
        try s.registerExport(.from(5));
        const before = s.exportRefcount(.from(5));
        try s.recordSend(.{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = &.{.{ .@"struct" = &.{
                    .{ .key = "cap", .value = .{ .reference = .{ .near = .{ .export_position = .from(5) } } } },
                } }},
                .answer = .from(1),
            },
        });
        try std.testing.expectEqual(before + 1, s.exportRefcount(.from(5)));
    }

    // Inbound (borrowed steady-state path): a far reference introduced inside a
    // struct entry installs its import.
    {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerExport(.from(7));
        const message = model.Message{
            .deliver = .{
                .target = .{ .near = model.NearRef.object(7) },
                .args = &.{.{ .@"struct" = &.{
                    .{ .key = "cap", .value = .{ .reference = .{ .far = .{ .import_position = .from(9) } } } },
                } }},
                .answer = .from(1),
            },
        };
        try std.testing.expect(!s.hasImport(.from(9)));
        try s.recordRecvView(model.view.Body.fromOwned(&message));
        try std.testing.expect(s.hasImport(.from(9)));
    }
}

test "send-side deliver nested past max_nesting_depth is refused before any export retain" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .limits = .{ .max_nesting_depth = 1 },
    });
    defer s.deinit();
    try s.registerImport(.from(2));
    try s.registerExport(.from(1));
    const before = s.exportRefcount(.from(1));

    // args = [ near(1), list(list([])) ]. The walk validates the shallow near
    // first (which apply would retain), then the over-deep list. Deciding
    // `NestingTooDeep` in validate, before apply mutates, keeps the retain
    // walk all-or-nothing: export 1's refcount must be untouched.
    const too_deep = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{
            .{ .reference = .{ .near = .{ .export_position = .from(1) } } },
            .{ .list = &.{.{ .list = &.{} }} },
        },
        .answer = null,
    } };
    try std.testing.expectError(session.Error.NestingTooDeep, s.recordSend(too_deep));
    try std.testing.expectEqual(before, s.exportRefcount(.from(1)));
}

test "send-side resolve fulfill nested past max_nesting_depth is refused before any export retain" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .limits = .{ .max_nesting_depth = 1 },
    });
    defer s.deinit();
    try s.registerExport(.from(1));
    const before = s.exportRefcount(.from(1));

    // A partner asks a question, giving us a pending inbound answer to resolve.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(11),
        .resolve_me_desc = .{ .far = model.FarRef.object(0) },
    } });

    // We resolve it with fulfill = list([ near(1), list(list([])) ]). The retain
    // walk would descend the list, retain the shallow near (export 1), then hit
    // the over-deep sublist and trip NestingTooDeep, mid-mutation. Deciding the
    // depth in validate, before apply retains, keeps it all-or-nothing: export
    // 1's refcount must be untouched. This is the resolve twin of the deliver
    // depth guard; the fix that closed the deliver path had left this one open.
    // The payload is heap-built with the session allocator: `recordSend`
    // consumes a resolve's resolution (moved into the store on success, freed
    // on refusal), so a comptime literal would be freed as if it were heap.
    const inner_empty = try allocator.alloc(model.Argument, 0);
    const inner = try allocator.alloc(model.Argument, 1);
    inner[0] = .{ .list = inner_empty };
    const top = try allocator.alloc(model.Argument, 2);
    top[0] = .{ .reference = .{ .near = .{ .export_position = .from(1) } } };
    top[1] = .{ .list = inner };
    const too_deep = model.Message{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .list = top } },
    } };
    // recordSend frees the resolution on this refusal; the test does not.
    try std.testing.expectError(session.Error.NestingTooDeep, s.recordSend(too_deep));
    try std.testing.expectEqual(before, s.exportRefcount(.from(1)));
}

test "session rejects unknown references at authority boundary" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = null,
        },
    }));

    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(9) } },
            .args = &.{},
            .answer = null,
        },
    }));
}
