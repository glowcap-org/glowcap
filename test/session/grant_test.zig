//! Addressability is an explicit grant (ADR-0027): a reserved export is
//! unaddressable until marshalled, a partner that releases everything loses
//! addressability, caps are decided in validate so refusals commit nothing,
//! a position outside the session's range is refused at every door, and an
//! export the partner does not hold is refused at every door it could name it.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

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

    // The partner never saw the rolled-back position, so it is the next one
    // minted: the slab hands a freed slot out before growing.
    const third = try s.allocateExport();
    try std.testing.expectEqual(second, third);
    try std.testing.expect(s.hasExport(third));
}

test "a reserved export is unaddressable until its first marshal grants it (ADR-0027)" {
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

    // The capability's first marshal, a deliver argument naming it, is the
    // grant; the identical inbound deliver is admitted afterwards.
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(3) } },
        .args = &.{.{ .reference = .{ .near = .{ .export_position = reserved } } }},
        .answer = .from(1),
    } });
    try s.recordRecv(probe);
    try std.testing.expect(s.inboundAnswer(.from(11)) != null);
}

test "a partner that releases every wire reference loses addressability until re-granted (ADR-0027)" {
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

test "registerExport is an explicit grant: the position is addressable with no marshal (ADR-0027)" {
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

test "import registration is bounded by max_imports (ADR-0008)" {
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

test "object and promise exports stop at the end of their range" {
    const allocator = std.testing.allocator;
    inline for (.{ session.Session.allocateExport, session.Session.allocatePromiseExport }) |allocate| {
        for ([_]u64{ 1, 3 }) |span| {
            const base: u64 = 1000;
            var s = session.Session.initWith(allocator, .{ .export_base = base, .export_span = span });
            defer s.deinit();

            for (base..base + span) |position| {
                try std.testing.expectEqual(@as(u64, position), (try allocate(&s)).int());
            }
            try std.testing.expectError(error.ExportRangeExhausted, allocate(&s));
        }
    }
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

test "the import cap holds across the introduced-import record's spill" {
    const allocator = std.testing.allocator;
    var s = session.Session.initWith(allocator, .{
        .limits = .{ .max_imports = 5 },
    });
    defer s.deinit();
    try s.registerExport(.from(7));

    // Six distinct fresh imports, more than the record holds in place, against
    // five free slots: refused in validate with nothing committed.
    const over = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{
            .{ .reference = .{ .far = .{ .import_position = .from(1) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(2) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(3) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(4) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(5) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(6) } } },
        },
        .answer = .from(11),
    } };
    try std.testing.expectError(
        session.Error.ImportCapExceeded,
        s.recordRecvView(model.view.Body.fromOwned(&over)),
    );
    try std.testing.expect(s.inboundAnswer(.from(11)) == null);
    try std.testing.expect(!s.hasImport(.from(1)));
    try std.testing.expect(!s.hasImport(.from(6)));

    // Five distinct imports each mentioned twice, with the repeats landing
    // after the record spilled, count once each and fill the table exactly.
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &.{
            .{ .reference = .{ .far = .{ .import_position = .from(1) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(2) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(3) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(4) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(5) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(1) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(2) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(3) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(4) } } },
            .{ .reference = .{ .far = .{ .import_position = .from(5) } } },
        },
        .answer = .from(12),
    } });
    try std.testing.expect(s.hasImport(.from(5)));
    try std.testing.expectEqual(@as(u64, 2), s.importRefcount(.from(1)));
    try std.testing.expectEqual(@as(u64, 2), s.importRefcount(.from(5)));
    try std.testing.expectError(session.Error.ImportCapExceeded, s.registerImport(.from(6)));
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

test "grant, reserve, and marshal keep fresh exports in range" {
    const allocator = std.testing.allocator;
    const span: u64 = 4;
    const Entry = enum { grant, reserve, marshal };
    for ([_]u64{ 1000, std.math.maxInt(u64) - span }) |base| {
        const end = base + span;
        for ([_]Entry{ .grant, .reserve, .marshal }) |entry| {
            var s = session.Session.initWith(allocator, .{ .export_base = base, .export_span = span });
            defer s.deinit();

            for ([_]u64{ base - 1, base, end - 1, end }) |number| {
                const position: model.ExportPosition = .from(number);
                const before = s.exports.nextPosition();
                const result = switch (entry) {
                    .grant => s.registerExport(position),
                    .reserve => s.reserveExport(position),
                    .marshal => s.retainSentExportRef(.{ .near = .{ .export_position = position } }),
                };
                if (number >= base and number < end) {
                    try result;
                    try std.testing.expect(s.hasExport(position));
                } else {
                    try std.testing.expectError(error.InvalidReference, result);
                    try std.testing.expectEqual(before, s.exports.nextPosition());
                    try std.testing.expect(!s.hasExport(position));
                }
            }
            const fresh = (try s.allocateExport()).int();
            try std.testing.expect(fresh >= base and fresh < end);
        }
    }
}

test "every inbound door refuses an export the partner does not hold (ADR-0027)" {
    const allocator = std.testing.allocator;
    // One rule, every door: a `near` the partner never received, or has
    // released, is refused wherever an inbound message can name one of our
    // exports. Each door is a separate reader of the export table, so each is
    // proved alone, in both unheld states, on both profiles.
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var s = session.Session.initWith(allocator, .{ .captp_version = profile });
        defer s.deinit();
        try s.registerImport(.from(3));
        const partner = model.Reference{ .far = .{ .import_position = .from(3) } };
        // Reserved: minted here, never marshalled.
        const reserved = try s.allocateExport();
        // Released: marshalled once, then every wire mention returned.
        const released = try s.allocateExport();
        try s.recordSend(.{ .deliver = .{
            .target = partner,
            .args = &.{.{ .reference = .{ .near = .{ .export_position = released } } }},
            .answer = .from(1),
        } });
        const release = [_]u64{released.int()};
        try s.recordRecv(.{ .gc_export = .{ .positions = &release, .deltas = &.{1} } });
        // A question we asked, for the resolve door.
        try s.recordSend(.{ .deliver = .{ .target = partner, .args = &.{}, .answer = .from(2) } });

        for ([_]model.ExportPosition{ reserved, released }) |position| {
            const near = model.Reference{ .near = .{ .export_position = position } };
            const bootstrap = model.Reference{ .near = .{ .export_position = .from(0) } };
            // The question and resolver every probe carries, so a refusal
            // that committed anything would leave an answer or an import.
            const resolver = model.Reference{ .far = model.FarRef.object(8) };
            // Deliver target.
            try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .deliver = .{
                .target = near,
                .args = &.{},
                .answer = .from(11),
                .resolve_me_desc = resolver,
            } }));
            // Deliver argument, on a target the partner holds.
            try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .deliver = .{
                .target = bootstrap,
                .args = &.{.{ .reference = near }},
                .answer = .from(11),
                .resolve_me_desc = resolver,
            } }));
            // Listen target.
            try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .listen = .{
                .target = near,
                .listener = .{ .far = model.FarRef.object(9) },
                .mode = .shortening_or_settling,
            } }));
            switch (profile) {
                // Projection receiver.
                .v1_0 => try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .get = .{
                    .receiver = near,
                    .field = "x",
                    .answer = .from(11),
                } })),
                // Fulfill payload of a resolve to our question.
                .next => try std.testing.expectError(error.InvalidReference, s.recordRecv(.{ .resolve = .{
                    .answer = .from(2),
                    .resolution = .{ .fulfill = .{ .reference = near } },
                } })),
            }
            // A release of what the partner does not hold.
            const positions = [_]u64{position.int()};
            try std.testing.expectError(error.GcUnderflow, s.recordRecv(.{ .gc_export = .{
                .positions = &positions,
                .deltas = &.{1},
            } }));
            // Every refusal committed nothing: no answer, no import, no hold.
            try std.testing.expect(s.inboundAnswer(.from(11)) == null);
            try std.testing.expect(!s.holdsImport(.from(8)));
            try std.testing.expect(!s.holdsImport(.from(9)));
            try std.testing.expectEqual(@as(u64, 0), s.exports.wireHeld(position));
            try std.testing.expect(s.hasExport(position));
        }
        try std.testing.expect(s.outboundAnswer(.from(2)) != null);
    }
}
