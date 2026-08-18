//! Addressability is an explicit grant (ADR-0074): a reserved export is
//! unaddressable until marshalled, a partner that releases everything loses
//! addressability, caps are decided in validate so refusals commit nothing,
//! and a position outside the session's range is refused at every door.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const session = pancake.ocapn.session;
const syrup = pancake.ocapn.codec.syrup;
const capnp = pancake.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

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

    var promise_session = session.Session.initWith(allocator, .{ .export_base = 2000, .export_span = 1 });
    defer promise_session.deinit();
    try std.testing.expectEqual(@as(u64, 2000), (try promise_session.allocatePromiseExport()).int());
    try std.testing.expectError(session.Error.ExportRangeExhausted, promise_session.allocatePromiseExport());
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

test "a V1.0 resolver accepts the complete u64 import space" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.installInboundResolver(.fromWire(.from(99)), .from(std.math.maxInt(u64)));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(std.math.maxInt(u64))),
        s.resolverForInboundAnswer(.fromWire(.from(99))),
    );
    try s.installInboundResolver(.fromWire(.from(100)), .from(@as(u64, 1) << 60));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(@as(u64, 1) << 60)),
        s.resolverForInboundAnswer(.fromWire(.from(100))),
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
