const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const session = pancake.ocapn.session;

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

test "an inbound set carrying two Equal elements is refused on both walk shapes" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // Owned walk: the duplicate is refused in validate, before apply mutates.
    var dup_elements = [_]model.Argument{ .{ .integer = 4 }, .{ .string = "mid" }, .{ .integer = 4 } };
    var dup_args = [_]model.Argument{.{ .set = &dup_elements }};
    const dup_deliver = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &dup_args,
        .answer = null,
    } };
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecv(dup_deliver));

    // Borrowed walk: the view projection of the same message is refused
    // identically, so neither dispatch path admits what the other refuses.
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecvView(model.view.Body.fromOwned(&dup_deliver)));

    // Two inner sets spelling one member in different element order are Equal
    // (set equality is order-independent), so the outer set still carries a
    // duplicate — this pins the hash's commutative combine to the equality it
    // serves.
    var inner_a = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    var inner_b = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };
    var nested_elements = [_]model.Argument{ .{ .set = &inner_a }, .{ .set = &inner_b } };
    var nested_args = [_]model.Argument{.{ .set = &nested_elements }};
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &nested_args,
        .answer = null,
    } }));

    // Distinct elements are admitted.
    var ok_elements = [_]model.Argument{ .{ .integer = 4 }, .{ .integer = 5 } };
    var ok_args = [_]model.Argument{.{ .set = &ok_elements }};
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &ok_args,
        .answer = null,
    } });
}

test "a wide equal-hashed set pair is refused by the comparison bound, not ground through" {
    const allocator = std.testing.allocator;

    // Two spellings of one wide set: the same members, in opposite order. Set
    // equality is multiset equality, so confirming this pair costs work
    // quadratic in the width, and the commutative set hash puts the pair in
    // one hash run so the fold actually confirms it. That is the shape a
    // partner buys with a single frame, and the elements here are distinct, so
    // the inner folds themselves spend nothing.
    const wide = 256;
    var forward: [wide]model.Argument = undefined;
    var backward: [wide]model.Argument = undefined;
    for (0..wide) |i| {
        forward[i] = .{ .integer = @intCast(i) };
        backward[i] = .{ .integer = @intCast(wide - 1 - i) };
    }
    var outer = [_]model.Argument{ .{ .set = &forward }, .{ .set = &backward } };
    var args = [_]model.Argument{.{ .set = &outer }};
    const deliver = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &args,
        .answer = null,
    } };

    // Under the default bound the work stops early and loud.
    var bounded = session.Session.init(allocator);
    defer bounded.deinit();
    try bounded.registerExport(.from(7));
    try std.testing.expectError(
        session.Error.CompareBudgetExhausted,
        bounded.recordRecvView(model.view.Body.fromOwned(&deliver)),
    );

    // Given room to finish, the same pair really is Equal: the bound refuses a
    // frame this session would otherwise have refused anyway, only sooner. So
    // the early refusal is the budget doing its job, not a wrong comparison.
    var generous = session.Session.initWith(allocator, .{ .limits = .{ .max_compare_visits = 1 << 24 } });
    defer generous.deinit();
    try generous.registerExport(.from(7));
    try std.testing.expectError(
        session.Error.DuplicateSetElement,
        generous.recordRecvView(model.view.Body.fromOwned(&deliver)),
    );

    // A narrow pair stays under the bound, so the budget cannot false-fire on
    // the ordinary duplicate refusal this fold exists for.
    var narrow_a = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    var narrow_b = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };
    var narrow_outer = [_]model.Argument{ .{ .set = &narrow_a }, .{ .set = &narrow_b } };
    var narrow_args = [_]model.Argument{.{ .set = &narrow_outer }};
    const narrow_deliver = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &narrow_args,
        .answer = null,
    } };
    var narrow = session.Session.init(allocator);
    defer narrow.deinit();
    try narrow.registerExport(.from(7));
    try std.testing.expectError(
        session.Error.DuplicateSetElement,
        narrow.recordRecvView(model.view.Body.fromOwned(&narrow_deliver)),
    );
}

test "a sent duplicate set element or struct key is refused pre-commit, not at encode" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    // The encoders refuse both duplicates too (ADR-0003), but an encode-time
    // refusal fires in `step`, after `retainSentExports` committed wire-delta
    // retains for a frame that never ships. `validateSend` refuses first, so
    // nothing commits: no outbound answer row is minted for the refused sends.
    var dup_elements = [_]model.Argument{ .{ .integer = 4 }, .{ .string = "mid" }, .{ .integer = 4 } };
    var dup_args = [_]model.Argument{.{ .set = &dup_elements }};
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &dup_args,
        .answer = .from(41),
    } }));
    try std.testing.expect(s.outboundAnswer(.from(41)) == null);

    var dup_entries = [_]model.StructEntry{
        .{ .key = "alpha", .value = .{ .integer = 1 } },
        .{ .key = "alpha", .value = .{ .integer = 2 } },
    };
    var struct_args = [_]model.Argument{.{ .@"struct" = &dup_entries }};
    try std.testing.expectError(session.Error.DuplicateStructKey, s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &struct_args,
        .answer = .from(42),
    } }));
    try std.testing.expect(s.outboundAnswer(.from(42)) == null);

    // Distinct keys and elements still send.
    var ok_entries = [_]model.StructEntry{
        .{ .key = "alpha", .value = .{ .integer = 1 } },
        .{ .key = "beta", .value = .{ .integer = 2 } },
    };
    var ok_args = [_]model.Argument{.{ .@"struct" = &ok_entries }};
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &ok_args,
        .answer = .from(43),
    } });
    try std.testing.expect(s.outboundAnswer(.from(43)) != null);
}

test "inbound deliver with a pathed promise target is refused, an empty path is not" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    // A prior inbound deliver mints answer 3 that a pipelined target can name.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(3),
    } });

    // A promise target carrying a non-empty pipeline path is refused: pancake
    // decomposes multi-hop sends before encode, so it never receives a pathed
    // inbound target — a path here names an inert, unvalidated payload. Both the
    // owned and the borrowed dispatch shapes refuse it identically.
    var ops = [_]model.PipelineOp{.{ .field = "manager" }};
    const pathed = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3), .path = .{ .ops = &ops } } },
        .args = &.{},
        .answer = null,
    } };
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecv(pathed));
    try std.testing.expectError(session.Error.UnexpectedMessage, s.recordRecvView(model.view.Body.fromOwned(&pathed)));

    // Negative control: the same target with an empty path is not refused for the
    // path — the refusal is specific to a non-empty path, not the promise target.
    const flat = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3), .path = .{} } },
        .args = &.{},
        .answer = null,
    } };
    if (s.recordRecv(flat)) |_| {} else |err| {
        try std.testing.expect(err != session.Error.UnexpectedMessage);
    }
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
    // violation, refused on recv — not deferred to our outbound resolve.
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

test "session records inbound answers and settles on resolve" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // Inbound deliver to our export 7. Post-flip (ADR-0010) the wire
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
    // partner never made. A partner that numbers its exports low — as Goblins
    // does — is liable to hold a live, unrelated object at that number, so the
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

test "inbound deliver to an unheld far target is rejected on both recv paths" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Import 7 is not held, so a deliver whose *target* is far import 7 names a
    // capability that does not exist for us. The borrowed steady-state path
    // (`recordRecvView`) and the owned retain path (`recordRecv`) share one
    // target-reference rule, so both must reject it as `InvalidReference`. The
    // view path previously accepted any far target; this is the regression guard.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "x" }},
            .answer = .from(1),
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

test "a partner introduction in the reserved redeemed-token range is refused" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(0)); // bootstrap, a held target to deliver to

    // A redeemed handoff token (>= REDEEMED_TOKEN_BASE) is minted by the
    // cross-connection node and never travels the wire, so a partner
    // *introducing* a far import in that range could only alias one — the
    // node's router would reroute the application's send to a different
    // connection's capability. The introduction gate refuses it. Here the
    // partner delivers to the held bootstrap and hands us, in an argument, a
    // far import at exactly the token base.
    const token_far = model.Argument{ .reference = .{ .far = .{ .import_position = .from(session.REDEEMED_TOKEN_BASE) } } };
    const poisoned = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &.{token_far},
            .answer = .from(1),
        },
    };
    try std.testing.expectError(
        session.Error.InvalidReference,
        s.recordRecvView(model.view.Body.fromOwned(&poisoned)),
    );

    // One below the base is an ordinary introduction and accepted, so the gate
    // refuses only the reserved range, not every large import position.
    const ok_far = model.Argument{ .reference = .{ .far = .{ .import_position = .from(session.REDEEMED_TOKEN_BASE - 1) } } };
    const clean = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &.{ok_far},
            .answer = .from(2),
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&clean));
}

test "inbound deliver to a held far target is accepted through the borrowed path" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    // The strict target rule accepts a far target we *do* hold, it rejects only
    // unheld ones, so the borrowed walker is not simply refusing every far.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "x" }},
            .answer = .from(1),
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&message));
    try std.testing.expect(s.inboundAnswer(.from(1)) != null);
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
        try s.registerImport(.from(7));
        try std.testing.expectError(session.Error.InvalidReference, s.recordSend(.{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
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
        try s.registerImport(.from(7));
        const message = model.Message{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
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
    try std.testing.expect(third.int() > second.int());
}

test "V1.0 outbound resolver export is reclaimed when its answer is gc'd, not leaked to teardown" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    // An answered deliver we send, so its answer exists to carry a resolver.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .bytes = "hi" }},
        .answer = .from(42),
    } });

    // Mint the V1.0 resolver export for that answer: `allocateExport`'s base
    // count-1 plus the wire mention's retain is count 2.
    const resolver = try s.mintOutboundResolver(.from(42));
    try std.testing.expectEqual(@as(u64, 2), s.exports.count(resolver));

    // The partner GCs its one wire mention. The base reference still floats, so
    // the partner's GC alone cannot reclaim the export.
    try s.recordRecv(.{ .gc_export = .{
        .positions = &.{resolver.int()},
        .deltas = &.{1},
    } });
    try std.testing.expect(s.hasExport(resolver));
    try std.testing.expectEqual(@as(u64, 1), s.exports.count(resolver));

    // We GC the answer. Its resolver can never fire again, so the base
    // reference is released and the export is reclaimed here, not left floating
    // until session teardown (the leak this pins).
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{42} } });
    try std.testing.expect(!s.hasExport(resolver));
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
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    // Local half first: stays negotiating until the partner's half lands.
    try s.recordSend(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.negotiating, s.state);
    try std.testing.expect(!s.handshakeComplete());
    try std.testing.expect(!s.hasExport(.from(session.BOOTSTRAP_POSITION)));

    // Partner half completes the handshake → open + bootstrap export@0.
    try s.recordRecv(startSessionMessage(.v1_0));
    try std.testing.expectEqual(session.State.open, s.state);
    try std.testing.expect(s.handshakeComplete());
    try std.testing.expect(s.hasExport(.from(session.BOOTSTRAP_POSITION)));
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

test "wire-delta GC decrements export and import refcounts by direction" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(3));
    try s.registerExport(.from(7));
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(.from(3)));
    const baseline = s.exportRefcount(.from(7));

    // Put one wire reference to export 7 in the partner's hands, the reference
    // its release below returns.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
        .answer = .from(1),
    } });
    try std.testing.expectEqual(baseline + 1, s.exportRefcount(.from(7)));

    // Outbound op:gc-exports releases our refs to the partner's exports →
    // decrements the import table, and may remove the row (an import carries
    // no local baseline). Inbound op:gc-exports is the partner releasing refs
    // to our exports → decrements the export table down to — never past — the
    // local baseline, so the row survives for re-export.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{3}, .deltas = &.{1} } });
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{1} } });

    try std.testing.expect(!s.hasImport(.from(3)));
    try std.testing.expect(s.hasExport(.from(7)));
    try std.testing.expectEqual(baseline, s.exportRefcount(.from(7)));
}

test "wire-delta GC underflow is a loud error and leaves refcounts intact" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(5));
    const before = s.exportRefcount(.from(5));

    // Delta exceeds what the wire holds → rejected, and the count is unchanged.
    try std.testing.expectError(session.Error.GcUnderflow, s.recordRecv(.{
        .gc_export = .{ .positions = &.{5}, .deltas = &.{2} },
    }));
    try std.testing.expectEqual(before, s.exportRefcount(.from(5)));

    // Unknown id → rejected.
    try std.testing.expectError(session.Error.GcUnderflow, s.recordSend(.{
        .gc_export = .{ .positions = &.{99}, .deltas = &.{1} },
    }));
}

test "re-sending an export retains its wire-delta so a matching gc-exports does not underflow" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    const baseline = s.exportRefcount(.from(7));

    // Introduce export 7 to the partner twice (two distinct outbound delivers,
    // export 7 named as an argument each time). Each wire crossing must retain.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
        .answer = .from(1),
    } });
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
        .answer = .from(2),
    } });
    // The two wire references the partner now holds, on top of the baseline.
    try std.testing.expectEqual(baseline + 2, s.exportRefcount(.from(7)));

    // A conformant partner that received export 7 twice releases with delta 2.
    // It must decrement cleanly — never underflow — and the export survives at
    // its pre-mention count for re-export.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{2} } });
    try std.testing.expectEqual(baseline, s.exportRefcount(.from(7)));
    try std.testing.expect(s.hasExport(.from(7)));
}

test "inbound gc-exports can never release an export's local baseline" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(3));
    try s.registerExport(.from(7));
    const baseline = s.exportRefcount(.from(7));

    // The partner receives export 7 twice.
    inline for (.{ 1, 2 }) |answer| {
        try s.recordSend(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(3) } },
            .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
            .answer = .from(answer),
        } });
    }

    // A hostile release of one more than the wire ever granted is refused
    // loudly. Validated against the raw refcount instead of the wire-held
    // share, it would have driven the row to zero and deleted it — a partner
    // killing our own live capability.
    const hostile = [_]u64{s.exportRefcount(.from(7))};
    try std.testing.expectError(session.Error.GcUnderflow, s.recordRecv(.{
        .gc_export = .{ .positions = &.{7}, .deltas = &hostile },
    }));
    try std.testing.expectEqual(baseline + 2, s.exportRefcount(.from(7)));

    // The conformant release of exactly the two wire references decrements to
    // the pre-mention count; the row stays live and our own next marshal of
    // the same capability is still valid.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{2} } });
    try std.testing.expectEqual(baseline, s.exportRefcount(.from(7)));
    try std.testing.expect(s.hasExport(.from(7)));
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
        .answer = .from(3),
    } });
    try std.testing.expectEqual(baseline + 1, s.exportRefcount(.from(7)));
}

test "a reserved export is unaddressable until its first marshal grants it (ADR-0074)" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(3));
    const reserved = try s.allocateExport();

    // A partner that guessed the reserved position is refused with the same
    // error a nonexistent export raises, so the probe cannot learn that a
    // reservation exists.
    const probe = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = reserved } },
        .args = &.{},
        .answer = .from(11),
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(probe));
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecvView(model.view.Body.fromOwned(&probe)));

    // The capability's first marshal — a deliver argument naming it — is the
    // grant; the identical inbound deliver is admitted afterwards.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = reserved } } }},
        .answer = .from(1),
    } });
    try s.recordRecv(probe);
    try std.testing.expect(s.inboundAnswer(.from(11)) != null);
}

test "a partner that releases every wire reference loses addressability until re-granted (ADR-0074)" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(3));
    const position = try s.allocateExport();

    const mention = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = position } } }},
        .answer = .from(1),
    } };
    try s.recordSend(mention);

    // Releasing the one wire reference returns the export to its reserved
    // state: the row survives at the local baseline, but the partner can no
    // longer address it.
    const positions = [_]u64{position.int()};
    try s.recordRecv(.{ .gc_export = .{ .positions = &positions, .deltas = &.{1} } });
    try std.testing.expect(s.hasExport(position));
    const probe = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = position } },
        .args = &.{},
        .answer = .from(11),
    } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(probe));

    // A fresh mention re-grants the same position.
    var regrant = mention;
    regrant.deliver.answer = .from(2);
    try s.recordSend(regrant);
    try s.recordRecv(probe);
    try std.testing.expect(s.inboundAnswer(.from(11)) != null);
}

test "registerExport is an explicit grant: the position is addressable with no marshal (ADR-0074)" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // No reference ever crossed the wire, and the partner can still address
    // the position: registerExport is the deliberate out-of-band grant.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
    } });
    try std.testing.expect(s.inboundAnswer(.from(11)) != null);
}

test "sending a projection op naming a near receiver retains its wire-delta" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    const baseline = s.exportRefcount(.from(7));

    // `op:get` / `op:index` / `op:untag` each put export 7 on the wire as the
    // projection receiver, exactly like a deliver target. Each crossing must
    // retain the wire-delta, or the partner's later release underflows.
    try s.recordSend(.{ .get = .{ .receiver = .{ .near = .{ .export_position = .from(7) } }, .field = "x", .answer = .from(1) } });
    try s.recordSend(.{ .index = .{ .receiver = .{ .near = .{ .export_position = .from(7) } }, .index = 0, .answer = .from(2) } });
    try s.recordSend(.{ .untag = .{ .receiver = .{ .near = .{ .export_position = .from(7) } }, .tag = "t", .answer = .from(3) } });
    // The three wire references the partner now holds, on top of the baseline.
    try std.testing.expectEqual(baseline + 3, s.exportRefcount(.from(7)));

    // The partner that received export 7 three times releases with delta 3; it
    // must decrement cleanly back to the pre-mention count, never underflow.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{3} } });
    try std.testing.expectEqual(baseline, s.exportRefcount(.from(7)));
    try std.testing.expect(s.hasExport(.from(7)));
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
                .exporter = .{ .transport = "memory", .designator = "exporter" },
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
            .wants_partial = false,
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

    try std.testing.expectError(session.Error.FeatureNotNegotiated, s.recordSend(.{
        .handoff = .{
            .give = .{
                .recipient_key = &.{},
                .exporter = .{ .transport = "memory", .designator = "exporter" },
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
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    try std.testing.expect(s.needsV1_0Translation());

    // Outbound: our answer 42 resolves via our local resolver export 7.
    try s.installOutboundResolver(.from(42), .from(7));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), s.answerForResolverExport(.from(7)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.answerForResolverExport(.from(8)));

    // Inbound: the partner's answer 99 resolves via their resolver import 3.
    try s.installInboundResolver(.from(99), .from(3));
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(3)), s.resolverForInboundAnswer(.from(99)));
    try std.testing.expectEqual(@as(?model.ImportPosition, null), s.resolverForInboundAnswer(.from(100)));
    // The inverse link is queryable too, keyed by the resolver import.
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(99)), s.answerForResolverImport(.from(3)));
}

test "nominateResolverExport installs the answer it hands back, so no caller can order it after the send" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .features = model.FeatureSet.full() });
    defer s.deinit();

    const nomination = try s.nominateResolverExport();

    // All three rows are live before the verb returns: the export, the answer,
    // and both directions of the link binding them.
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(nomination.resolver_export));
    try std.testing.expect(s.outbound_answers.contains(nomination.answer));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, nomination.answer),
        s.answerForResolverExport(nomination.resolver_export),
    );
    try std.testing.expectEqual(
        @as(?model.ExportPosition, nomination.resolver_export),
        s.outbound_resolver_link.getByValue(nomination.answer),
    );

    // A second nomination shares nothing with the first.
    const second = try s.nominateResolverExport();
    try std.testing.expect(second.resolver_export != nomination.resolver_export);
    try std.testing.expect(second.answer != nomination.answer);

    // And abandoning one takes its export, its link, and its answer row away,
    // leaving the other nomination whole.
    s.abandonResolverNomination(nomination);
    try std.testing.expectEqual(@as(u64, 0), s.exportRefcount(nomination.resolver_export));
    try std.testing.expect(!s.outbound_answers.contains(nomination.answer));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, null),
        s.answerForResolverExport(nomination.resolver_export),
    );
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, second.answer),
        s.answerForResolverExport(second.resolver_export),
    );
    try std.testing.expect(s.outbound_answers.contains(second.answer));
}

test "v1.0 gc-answers drops both directions of the inbound resolver link" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();

    // The partner delivers to our export 1, opening inbound answer 99, and we
    // record resolver import 3 as its resolve-me target (both link directions).
    try s.registerExport(.from(1));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(99),
    } });
    try s.installInboundResolver(.from(99), .from(3));
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(3)), s.resolverForInboundAnswer(.from(99)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(99)), s.answerForResolverImport(.from(3)));

    // The partner GCs the answer: the forward map and its inverse drop together,
    // so a long-lived session never accumulates orphaned reverse-link rows.
    try s.recordRecv(.{ .gc_answer = .{ .positions = &.{99} } });
    try std.testing.expectEqual(@as(?model.ImportPosition, null), s.resolverForInboundAnswer(.from(99)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.answerForResolverImport(.from(3)));
}

test "v1.0 borrowed inbound raw resolve is rejected" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(7));
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
    } });
    const message = model.Message{ .resolve = .{
        .answer = .from(11),
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
    try s.registerExport(.from(1));
    try s.registerImport(.from(1));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(5),
    } });
    try std.testing.expect(!s.answerResolved(.from(5)));

    // Queue two pipelined calls; the session takes ownership of each.
    try s.enqueuePipelinedCall(.from(5), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "a") } });
    try s.enqueuePipelinedCall(.from(5), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "b") } });

    // Queueing against an unknown answer is rejected and frees the message
    // (the testing allocator would flag a leak otherwise).
    try std.testing.expectError(error.InvalidReference, s.enqueuePipelinedCall(
        .from(99),
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "z") } },
    ));

    // A listener (POD listener cap) and a stored resolution.
    try s.installListener(.from(5), .{ .listener = .{ .import_position = .from(1) }, .wants_partial = false });
    try s.storeResolution(.from(5), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } });
    try std.testing.expect(s.answerResolved(.from(5)));
    const peeked = s.peekResolution(.from(5)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(peeked.* == .fulfill);

    // Drain transfers ownership of the queued calls to the caller; a second
    // drain is empty.
    const drained = try s.takePipelinedCalls(.from(5));
    defer {
        for (drained) |message| model.freeMessage(allocator, message);
        allocator.free(drained);
    }
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    const empty = try s.takePipelinedCalls(.from(5));
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Draining listeners likewise empties the list (entries are POD; only the
    // slice is owned); a second drain is empty.
    const listeners = try s.takePipelinedListeners(.from(5));
    defer allocator.free(listeners);
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(usize, 0), (try s.takePipelinedListeners(.from(5))).len);
}

test "pipelining caps fail loud rather than silently dropping" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .queue_cap = 2, .max_listeners_per_target = 1 },
    });
    defer s.deinit();

    // Export 1 hosts the inbound deliver target (post-flip `.near`); import 1
    // backs the `.far` listener target.
    try s.registerExport(.from(1));
    try s.registerImport(.from(1));
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(7),
    } });

    try s.enqueuePipelinedCall(.from(7), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "1") } });
    try s.enqueuePipelinedCall(.from(7), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "2") } });
    try std.testing.expectError(error.QueueCapExceeded, s.enqueuePipelinedCall(
        .from(7),
        .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "3") } },
    ));

    try s.installListener(.from(7), .{ .listener = .{ .import_position = .from(1) }, .wants_partial = false });
    try std.testing.expectError(error.ListenerCapExceeded, s.installListener(
        .from(7),
        .{ .listener = .{ .import_position = .from(1) }, .wants_partial = false },
    ));
}

test "imported-promise substrate owns host, listeners, and relayed resolution" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Root import 5 at a third-party host; idempotent for the same host.
    try s.installThirdPartyImport(.from(5), "host-a");
    try std.testing.expect(s.isThirdPartyImport(.from(5)));
    try std.testing.expect(!s.isThirdPartyImport(.from(6)));
    try s.installThirdPartyImport(.from(5), "host-a");

    // Re-rooting at a different host is a loud error.
    try std.testing.expectError(error.HostMismatch, s.installThirdPartyImport(.from(5), "host-b"));

    // A listener (POD far listener cap) and a stored relayed resolution.
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });
    try std.testing.expect(try s.recordRelayedResolution(.from(5), s.importedPromiseRowId(.from(5)).?, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } }));
    const peeked = s.importedPromiseResolution(.from(5)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("v", peeked.fulfill.bytes);

    // A second relayed resolution is refused — a promise resolves once,
    // mirroring the answer-side rule — the refused value is freed (no leak),
    // and the stored value is untouched.
    try std.testing.expectError(error.UnexpectedMessage, s.recordRelayedResolution(
        .from(5),
        s.importedPromiseRowId(.from(5)).?,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "w") } },
    ));
    try std.testing.expectEqualStrings("v", s.importedPromiseResolution(.from(5)).?.fulfill.bytes);

    // Recording on an unknown import frees the resolution and errors.
    try std.testing.expectError(error.InvalidReference, s.recordRelayedResolution(
        .from(99),
        0,
        .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "z") } },
    ));

    // Drain empties the list (entries are POD; only the slice is owned); a
    // second drain is empty.
    const listeners = try s.takeImportedPromiseListeners(.from(5));
    defer allocator.free(listeners);
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(usize, 0), (try s.takeImportedPromiseListeners(.from(5))).len);
}

test "imported-promise listener cap fails loud" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_listeners_per_target = 1 },
    });
    defer s.deinit();

    try s.installThirdPartyImport(.from(5), "h");
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });
    try std.testing.expectError(error.ListenerCapExceeded, s.installImportedPromiseListener(
        .from(5),
        .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false },
    ));
    // A listener on an unknown (non-third-party) import errors.
    try std.testing.expectError(error.InvalidReference, s.installImportedPromiseListener(
        .from(99),
        .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false },
    ));
}

test "outbound gc-export releasing a third-party import drops its imported-promise row" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.installThirdPartyImport(.from(5), "h");
    try s.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });
    try std.testing.expect(try s.recordRelayedResolution(.from(5), s.importedPromiseRowId(.from(5)).?, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } }));
    try std.testing.expect(s.isThirdPartyImport(.from(5)));

    // Outbound op:gc-exports releasing import 5 (count 1 → 0) evicts the row,
    // freeing the host designator, the listener cap, and the stored resolution.
    try s.recordSend(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });
    try std.testing.expect(!s.isThirdPartyImport(.from(5)));
    try std.testing.expect(s.importedPromiseResolution(.from(5)) == null);
}

test "requeue moves a pipelined call to a new target and detects cycles" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Two pending inbound answers: 1 (resolves to a promise on 2) and 2.
    // Both arrive as inbound delivers to our export 1 (post-flip `.near`).
    try s.registerExport(.from(1));
    inline for (.{ 1, 2 }) |answer| {
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = .from(1) } },
            .args = &.{},
            .answer = .from(answer),
        } });
    }

    // A call pipelined against answer 1.
    try s.enqueuePipelinedCall(.from(1), .{ .abort = .{ .kind = .other, .message = try allocator.dupe(u8, "call") } });

    // Answer 1 resolved to promise(2): drain 1's calls and requeue onto 2, with
    // 1 on the seen chain. 2 is not seen, so this succeeds and 2 owns the call.
    const drained = try s.takePipelinedCalls(.from(1));
    defer allocator.free(drained);
    for (drained) |call| try s.requeuePipelinedCall(.from(2), &.{.from(1)}, call);

    // A cycle: answer 2 resolves back to promise(1), but 1 is already on the
    // chain, requeue fails loudly and frees the call (no leak).
    const drained2 = try s.takePipelinedCalls(.from(2));
    defer allocator.free(drained2);
    for (drained2) |call| {
        try std.testing.expectError(error.ResolutionCycle, s.requeuePipelinedCall(.from(1), &.{ .from(1), .from(2) }, call));
    }
}

test "next session needs no v1.0 resolver translation" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
    });
    defer s.deinit();
    try std.testing.expect(!s.needsV1_0Translation());
}

test "gc-answers prunes the outbound resolver link when the answer is released" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.v1_0,
        .features = model.FeatureSet.full(),
    });
    defer s.deinit();
    try s.registerImport(.from(7));

    // Send a question (answer 5) and commit its resolver export, as the runtime
    // does when augmenting the outbound deliver.
    try s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(5),
        },
    });
    try s.installOutboundResolver(.from(5), .from(1));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(5)), s.answerForResolverExport(.from(1)));

    // We allocated the question, so we are the side that GCs it: sending
    // `op:gc-answers` for our own answer-pos releases the outbound answer and
    // prunes the resolver link alongside it (CapTP spec § op:gc-answers).
    try s.recordSend(.{ .gc_answer = .{ .positions = &.{5} } });
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), s.answerForResolverExport(.from(1)));
}

test "import registration is bounded by max_imports (ADR-0025)" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_imports = 2 },
    });
    defer s.deinit();

    try s.registerImport(.from(1));
    try s.registerImport(.from(2));
    // Re-registering a held id is idempotent and never trips the cap.
    try s.registerImport(.from(1));
    // A third *new* import overflows the table.
    try std.testing.expectError(session.Error.ImportCapExceeded, s.registerImport(.from(3)));
    try std.testing.expect(!s.hasImport(.from(3)));
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

test "send-side deliver nested past max_nesting_depth is refused before any export retain" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .limits = .{ .max_nesting_depth = 1 },
    });
    defer s.deinit();
    try s.registerExport(.from(1));
    const before = s.exportRefcount(.from(1));

    // args = [ near(1), list(list([])) ]. The walk validates the shallow near
    // first (which apply would retain), then the over-deep list. Deciding
    // `NestingTooDeep` in validate — before apply mutates — keeps the retain
    // walk all-or-nothing: export 1's refcount must be untouched.
    const too_deep = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
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
    } });

    // We resolve it with fulfill = list([ near(1), list(list([])) ]). The retain
    // walk would descend the list, retain the shallow near (export 1), then hit
    // the over-deep sublist and trip NestingTooDeep — mid-mutation. Deciding the
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

test "inbound answers are bounded by max_inbound_answers (ADR-0025)" {
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

test "an inbound answer-pos in the reserved virtual range is refused on both recv paths" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(1));

    // Answer positions are partner-named, so the virtual namespace the session
    // allocates from (V1.0 resolver-only fetches) is only collision-free
    // because the partner is refused that range here.
    const message = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(session.VIRTUAL_INBOUND_ANSWER_BASE),
    } };
    try std.testing.expectError(
        session.Error.InvalidReference,
        s.recordRecvView(model.view.Body.fromOwned(&message)),
    );
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(message));

    // The session's own virtual allocator hands out exactly that range.
    try std.testing.expect(s.allocateInboundAnswer().int() >= session.VIRTUAL_INBOUND_ANSWER_BASE);

    // The position just below the base is an ordinary partner choice.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(session.VIRTUAL_INBOUND_ANSWER_BASE - 1),
    } });
}

test "a session that exhausts its export range refuses rather than naming a neighbour's object" {
    const allocator = std.testing.allocator;
    // The export allocator is monotonic and counts positions ever minted, not
    // live ones, so a long-lived session that mints and releases would walk
    // past the range its host gave it and start naming positions that belong to
    // the next session along — the exact aliasing the ranges exist to prevent.
    var s = session.Session.initWith(allocator, .{ .export_base = 1000, .export_span = 3 });
    defer s.deinit();

    try std.testing.expectEqual(@as(u64, 1000), (try s.allocateExport()).int());
    try std.testing.expectEqual(@as(u64, 1001), (try s.allocateExport()).int());
    try std.testing.expectEqual(@as(u64, 1002), (try s.allocateExport()).int());
    try std.testing.expectError(session.Error.ExportRangeExhausted, s.allocateExport());
}

test "a projection op answers to the same inbound answer-pos rules as a deliver" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(1));

    // `op:get` / `op:index` / `op:untag` each name an answer of their own and
    // install a row exactly as a deliver does, so a partner reaching into the
    // engine's virtual range through one of them would fuse its question with
    // an answer the session allocated for itself.
    const receiver = model.Reference{ .near = .{ .export_position = .from(1) } };
    const reserved = model.AnswerPosition.from(session.VIRTUAL_INBOUND_ANSWER_BASE);
    const get = model.Message{ .get = .{ .receiver = receiver, .field = "field", .answer = reserved } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(get));
    const index = model.Message{ .index = .{ .receiver = receiver, .index = 0, .answer = reserved } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(index));
    const untag = model.Message{ .untag = .{ .receiver = receiver, .tag = "t", .answer = reserved } };
    try std.testing.expectError(session.Error.InvalidReference, s.recordRecv(untag));

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

test "inbound gc-exports naming the pinned bootstrap position is a no-op" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.transitionToOpen(); // installs the bootstrap export at position 0
    try s.registerImport(.from(3));
    try s.registerExport(.from(7));

    // A partner that accounted its bootstrap import (Goblins installs import 0
    // with a gc will-handler) may release it. Position 0 is pinned outside
    // wire-delta accounting, so the release is skipped, it neither kills the
    // bootstrap export nor underflows.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{0}, .deltas = &.{1} } });
    try std.testing.expect(s.hasExport(.from(session.BOOTSTRAP_POSITION)));

    // A later bootstrap fetch still has its target.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{ .{ .symbol = "fetch" }, .{ .bytes = "swiss" } },
        .answer = .from(1),
    } });

    // Hand the partner one wire reference to export 7, so its release below is
    // a legal wire-delta.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
        .answer = .from(2),
    } });
    const held = s.exportRefcount(.from(7));

    // Skipping position 0 does not skip its neighbors in the same message:
    // export 7's mention is released even though it rides beside the pinned
    // bootstrap position.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{ 0, 7 }, .deltas = &.{ 5, 1 } } });
    try std.testing.expect(s.hasExport(.from(session.BOOTSTRAP_POSITION)));
    try std.testing.expectEqual(held - 1, s.exportRefcount(.from(7)));
}

test "mentioning the bootstrap export then receiving its gc never underflows" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.transitionToOpen();
    try s.registerImport(.from(3));

    // Mention our bootstrap export as a deliver argument: `retainSentExports`
    // deliberately never counts position 0, so the partner's accounting and
    // ours disagree about wire references to it, which is exactly why an
    // inbound release of position 0 must be a pinned no-op, never arithmetic.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(session.BOOTSTRAP_POSITION) } } }},
        .answer = .from(1),
    } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(.from(session.BOOTSTRAP_POSITION)));

    // The partner received the bootstrap mention and releases with its own
    // delta. No underflow, no spurious abort, bootstrap intact.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{0}, .deltas = &.{2} } });
    try std.testing.expectEqual(@as(u64, 1), s.exportRefcount(.from(session.BOOTSTRAP_POSITION)));
}

test "outbound gc-exports naming the partner bootstrap is refused" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // Our import 0 is the partner's pinned bootstrap, reachable without a
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
    // the handshake. The owned path used to skip both, the regression guard.
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
    // Nine distinct live exports so the fold spills past the stack threshold
    // into the heap map — the path that can surface a host OutOfMemory.
    var positions: [9]u64 = undefined;
    var deltas: [9]u64 = undefined;
    var i: u64 = 0;
    while (i < positions.len) : (i += 1) {
        const pos = i + 1;
        positions[i] = pos;
        deltas[i] = 1;
        try s.registerExport(.from(pos));
    }
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(1) } },
        .args = &.{},
        .answer = .from(11),
    } });
    // Eight more answers so gc-answers also spills.
    var answer_positions: [9]u64 = undefined;
    i = 0;
    while (i < answer_positions.len) : (i += 1) {
        answer_positions[i] = 11 + i;
        if (i > 0) {
            try s.recordRecv(.{ .deliver = .{
                .target = .{ .near = .{ .export_position = .from(1) } },
                .args = &.{},
                .answer = .from(11 + i),
            } });
        }
    }

    // The spill map inside the gc validators allocates; that failure is a
    // host condition, not a partner protocol violation, and must surface as
    // OutOfMemory (no abort) rather than a spurious GcUnderflow abort.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, session.checkGcExportDecrement(
        failing.allocator(),
        &s.exports,
        .{ .positions = &positions, .deltas = &deltas },
    ));
    var failing_answers = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, session.checkGcAnswerDecrement(
        failing_answers.allocator(),
        &s.inbound_answers,
        &answer_positions,
    ));
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

test "the import cap is decided in validate, so a refused deliver commits nothing" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_imports = 2 },
    });
    defer s.deinit();
    try s.registerExport(.from(7));
    try s.registerImport(.from(1));

    // Two fresh introductions against one free slot: refused during the
    // validate walk, before apply installs the answer row or either import,
    // the all-or-nothing contract in apply.zig, proven rather than narrated.
    const over = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{
            .{ .reference = .{ .far = .{ .import_position = .from(8) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(9) } } },
        },
        .answer = .from(11),
    } };
    try std.testing.expectError(
        session.Error.ImportCapExceeded,
        s.recordRecvView(model.view.Body.fromOwned(&over)),
    );
    try std.testing.expectError(session.Error.ImportCapExceeded, s.recordRecv(over));
    try std.testing.expect(s.inboundAnswer(.from(11)) == null);
    try std.testing.expect(!s.hasImport(.from(8)));
    try std.testing.expect(!s.hasImport(.from(9)));

    // One new import repeated twice counts once, the second mention is a
    // refcount refresh, exactly as `registerImport` treats it in apply.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{
            .{ .reference = .{ .far = .{ .import_position = .from(8) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(8) } } },
        },
        .answer = .from(12),
    } });
    try std.testing.expect(s.hasImport(.from(8)));
    try std.testing.expectEqual(@as(u64, 2), s.importRefcount(.from(8)));
}

test "the import cap on a resolve fulfill payload is decided in validate" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .limits = .{ .max_imports = 1 },
    });
    defer s.deinit();
    try s.registerImport(.from(5));

    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(5) } },
        .args = &.{},
        .answer = .from(11),
    } });

    // The fulfill introduces a new import past the cap: refused in validate,
    // so the answer is still pending and the import was never installed.
    const over = model.Message{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(9) } } } },
    } };
    try std.testing.expectError(
        session.Error.ImportCapExceeded,
        s.recordRecvView(model.view.Body.fromOwned(&over)),
    );
    try std.testing.expect(!s.hasImport(.from(9)));
    try std.testing.expectEqual(session.AnswerStatus.pending, s.outboundAnswer(.from(11)).?.status);
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
    } });
    try std.testing.expectEqual(session.AnswerStatus.pending, s.inboundAnswer(.from(11)).?.status);
}

test "a V1.0 resolver cannot claim an import in the node's reserved range" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    // A partner advertises its resolver by naming an import position in the
    // deliver's `resolve_me_desc`, and this path installs that row itself
    // rather than looking one up, so the ordinary reference checks never see
    // the position. Everything at or above `REDEEMED_TOKEN_BASE` belongs to the
    // node, which hands those ids to the application for redeemed capabilities
    // and relies on them never colliding with a partner's import.
    try std.testing.expectError(
        session.Error.InvalidReference,
        s.installInboundResolver(.from(99), .from(session.REDEEMED_TOKEN_BASE)),
    );
    try std.testing.expectError(
        session.Error.InvalidReference,
        s.installInboundResolver(.from(99), .from(std.math.maxInt(u64))),
    );
    // Nothing was installed by the refused calls.
    try std.testing.expectEqual(@as(?model.ImportPosition, null), s.resolverForInboundAnswer(.from(99)));

    // The position just below the range is an ordinary import and still works.
    try s.installInboundResolver(.from(99), .from(session.REDEEMED_TOKEN_BASE - 1));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(session.REDEEMED_TOKEN_BASE - 1)),
        s.resolverForInboundAnswer(.from(99)),
    );
}

test "an export position from outside this session's range is refused at every door" {
    const allocator = std.testing.allocator;
    // A host gives each session a disjoint slice of the export numbers, so a
    // position outside this session's slice is a name in some other
    // conversation. Three doors let one in from outside the allocator — an
    // explicit grant, a reservation, and the first marshal of a sent resolve —
    // and each used to mint a row for it. Above the range that also dragged
    // the allocator past its own end, after which the session could export
    // nothing at all.
    var s = session.Session.initWith(allocator, .{ .export_base = 1000, .export_span = 100 });
    defer s.deinit();

    // Inside the range: all three doors admit.
    try s.registerExport(.from(1000));
    try s.reserveExport(.from(1050));
    try s.retainSentExportRef(.{ .near = .{ .export_position = .from(1060) } });

    // Above it — another session's numbers, and the half that kills this one.
    try std.testing.expectError(error.InvalidReference, s.registerExport(.from(1100)));
    try std.testing.expectError(error.InvalidReference, s.reserveExport(.from(5000)));
    try std.testing.expectError(
        error.InvalidReference,
        s.retainSentExportRef(.{ .near = .{ .export_position = .from(9999) } }),
    );

    // Below it names an object this session does not host just as surely, and
    // is the half a high-end-only check would have let through.
    try std.testing.expectError(error.InvalidReference, s.registerExport(.from(999)));
    try std.testing.expectError(error.InvalidReference, s.reserveExport(.from(1)));
    try std.testing.expectError(
        error.InvalidReference,
        s.retainSentExportRef(.{ .near = .{ .export_position = .from(500) } }),
    );

    // The allocator is untouched by every refusal, which is the damage the
    // range exists to prevent.
    try std.testing.expect(s.next_export_position <= 1061);
    const fresh = try s.allocateExport();
    try std.testing.expect(fresh.int() >= 1000 and fresh.int() < 1100);
}
