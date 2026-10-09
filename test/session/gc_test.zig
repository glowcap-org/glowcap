//! Wire-delta GC: refcounts move by direction, zero deltas are refused
//! before any mutation in both profiles and codecs, underflow is loud, a
//! re-sent export retains its delta, the local baseline and the pinned
//! bootstrap position are never releasable, scratch OOM reports itself, and a
//! send refused for memory takes no export retain.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

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

test "gc-exports zero delta is rejected by structural validation" {
    try std.testing.expectError(session.Error.MalformedMessage, session.validateGcExport(.{
        .positions = &.{7},
        .deltas = &.{0},
    }));
    try std.testing.expectError(session.Error.MalformedMessage, session.validateGcExport(.{
        .positions = &.{ 7, 8 },
        .deltas = &.{ 1, 0 },
    }));
}

test "gc-exports zero delta outbound refusal precedes import mutation in both profiles" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        var s = session.Session.initWith(std.testing.allocator, .{ .captp_version = profile });
        defer s.deinit();
        try s.registerImport(.from(7));
        const before = s.importRefcount(.from(7));

        try std.testing.expectError(session.Error.MalformedMessage, s.recordSend(.{
            .gc_export = .{ .positions = &.{7}, .deltas = &.{0} },
        }));

        try std.testing.expectEqual(before, s.importRefcount(.from(7)));
    }
}

test "gc-exports zero delta inbound refusal precedes export mutation in both profiles" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        var s = session.Session.initWith(std.testing.allocator, .{ .captp_version = profile });
        defer s.deinit();
        try s.registerExport(.from(7));
        const before = s.exportRefcount(.from(7));

        try std.testing.expectError(session.Error.MalformedMessage, s.recordRecv(.{
            .gc_export = .{ .positions = &.{7}, .deltas = &.{0} },
        }));

        try std.testing.expectEqual(before, s.exportRefcount(.from(7)));
    }
}

test "gc-exports zero delta from both codecs reaches session validation before mutation" {
    const allocator = std.testing.allocator;
    const message = model.Message{ .gc_export = .{ .positions = &.{7}, .deltas = &.{0} } };

    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        {
            var s = session.Session.initWith(allocator, .{ .captp_version = profile, .codec = .syrup });
            defer s.deinit();
            try s.registerExport(.from(7));
            const before = s.exportRefcount(.from(7));
            var frame = try syrup.encodeMessageForProfile(allocator, profile, message);
            defer frame.deinit();
            const body = try syrup.decodeBody(frame.view());

            try std.testing.expectError(session.Error.MalformedMessage, s.recordRecvView(body));
            try std.testing.expectEqual(before, s.exportRefcount(.from(7)));
        }
        {
            var s = session.Session.initWith(allocator, .{ .captp_version = profile, .codec = .capnp });
            defer s.deinit();
            try s.registerExport(.from(7));
            const before = s.exportRefcount(.from(7));
            var frame = try capnp.encodeMessage(allocator, message);
            defer frame.deinit();
            const body = try capnp.decodeBody(frame.view());

            try std.testing.expectError(session.Error.MalformedMessage, s.recordRecvView(body));
            try std.testing.expectEqual(before, s.exportRefcount(.from(7)));
        }
    }
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

    // An untrusted release of one more than the wire ever granted is refused
    // loudly. Validated against the raw refcount instead of the wire-held
    // share, it would have driven the row to zero and deleted it — a partner
    // killing our own live capability.
    const over_release = [_]u64{s.exportRefcount(.from(7))};
    try std.testing.expectError(session.Error.GcUnderflow, s.recordRecv(.{
        .gc_export = .{ .positions = &.{7}, .deltas = &over_release },
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

test "sending a projection op naming a near receiver retains its wire-delta" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{ .captp_version = .next });
    defer s.deinit();
    try s.registerExport(.from(7));
    const baseline = s.exportRefcount(.from(7));

    // `op:get` / `op:index` / `op:untag` each put export 7 on the wire as the
    // projection receiver, exactly like a deliver target. Each crossing must
    // retain the wire-delta, or the partner's later release underflows.
    try s.recordSend(.{ .get = .{ .receiver = .{ .near = .{ .export_position = .from(7) } }, .field = "x", .answer = .from(1) } });
    try s.recordSend(.{ .index = .{ .receiver = .{ .near = .{ .export_position = .from(7) } }, .index = .{ .integer = 0 }, .answer = .from(2) } });
    try s.recordSend(.{ .untag = .{ .receiver = .{ .near = .{ .export_position = .from(7) } }, .tag = "t", .answer = .from(3) } });
    // The three wire references the partner now holds, on top of the baseline.
    try std.testing.expectEqual(baseline + 3, s.exportRefcount(.from(7)));

    // The partner that received export 7 three times releases with delta 3; it
    // must decrement cleanly back to the pre-mention count, never underflow.
    try s.recordRecv(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{3} } });
    try std.testing.expectEqual(baseline, s.exportRefcount(.from(7)));
    try std.testing.expect(s.hasExport(.from(7)));
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

    // Mention our bootstrap export as a deliver argument: send-side export accounting
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

test "a send refused for memory takes no export retain" {
    // Validation requires a live row for every sent `near`, so the retain walk
    // only increments rows. Failing each allocation in turn must leave every
    // count as it was: a refused send put nothing on the wire.
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var s = session.Session.init(failing.allocator());
        defer s.deinit();
        var args: [17]model.Argument = undefined;
        for (&args, 7..) |*arg, position| {
            try s.registerExport(.from(position));
            arg.* = .{ .reference = .{ .near = .{ .export_position = .from(position) } } };
        }
        const baseline = s.exportRefcount(.from(7));

        failing.fail_index = failing.alloc_index + fail_after;
        s.recordSend(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
            .args = &args,
            .answer = .from(1),
        } }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            for (7..24) |position| try std.testing.expectEqual(baseline, s.exportRefcount(.from(position)));
            continue;
        };
        for (7..24) |position| try std.testing.expectEqual(baseline + 1, s.exportRefcount(.from(position)));
        break;
    }
}
