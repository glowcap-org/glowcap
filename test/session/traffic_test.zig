//! Session delivery admission, answer uniqueness, nesting limits, and
//! reference arguments. Target roles are in descriptor_roles_test.zig.

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
    // No registerImport(bootstrap_position): the partner bootstrap (import 0) is
    // always reachable on an open session, the bootstrap-fetch send target.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(session.bootstrap_position) } },
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

test "inbound deliver nested far past the ceiling fails closed" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // Build an argument tree nested deeper than the cap. A bump arena owns the
    // scratch tree; the test only needs it to live across the one recordRecv.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cap = model.max_value_depth;
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

test "partner introductions accept the complete u64 import space" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    // The pinned bootstrap export is always a valid inbound `desc:export 0`
    // target, without a table grant.

    const high_far = model.Argument{ .reference = .{ .far = .{ .import_position = .from(std.math.maxInt(u64)) } } };
    const high = model.Message{
        .deliver = .{
            .target = .{ .near = model.NearRef.object(session.bootstrap_position) },
            .args = &.{high_far},
            .answer = .from(1),
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&high));
    try std.testing.expect(s.hasImport(.from(std.math.maxInt(u64))));

    const old_boundary = model.Argument{ .reference = .{ .far = .{ .import_position = .from(@as(u64, 1) << 60) } } };
    const clean = model.Message{
        .deliver = .{
            .target = .{ .near = model.NearRef.object(session.bootstrap_position) },
            .args = &.{old_boundary},
            .answer = .from(2),
        },
    };
    try s.recordRecvView(model.view.Body.fromOwned(&clean));
}

test "a reference inside a Struct argument crosses every session walk" {
    // Struct entries carry full argument values (ADR-0005), so a reference can
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
