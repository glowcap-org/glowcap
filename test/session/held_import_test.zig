//! A stored resolution holds the import rows it names (ADR-0070): a release
//! naming a held row stays off the wire and with the table, a caller's as the
//! session's and the session's as held back, and the retains leave when the
//! last hold does. A Host handle lifted while every retain is held back takes
//! one back. `Session.wireRelease` decides what a frame carries.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

fn position(value: u64) model.ImportPosition {
    return .from(value);
}

test "a caller's release of a held row stays with the table until the hold leaves" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    try s.registerImport(position(9));
    s.imports.holdForResolution(position(9));

    try s.imports.decrement(position(9), 1);
    try std.testing.expectEqual(@as(u64, 2), s.importRefcount(position(9)));
    try std.testing.expectEqual(@as(u64, 1), s.importReleasable(position(9)));
    try std.testing.expectEqual(@as(u64, 1), s.imports.sessionHeld(position(9)));

    // The hold leaves with the retain it kept back, which the session releases.
    try std.testing.expectEqual(@as(u64, 1), s.imports.releaseResolutionHold(position(9)));
    try std.testing.expect(!s.imports.heldByResolution(position(9)));
    s.imports.releaseSessionHeld(position(9), 1);
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(position(9)));
    try s.imports.decrement(position(9), 1);
    try std.testing.expect(!s.holdsImport(position(9)));
}

test "a caller's release past the releasable count underflows on a held row too" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    s.imports.holdForResolution(position(9));
    try std.testing.expectError(error.GcUnderflow, s.imports.decrement(position(9), 2));
    try std.testing.expectEqual(@as(u64, 1), s.importReleasable(position(9)));
}

test "the session's own release of a held row is held back" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.retainImportForSession(position(9));
    s.imports.holdForResolution(position(9));

    s.imports.releaseSessionHeld(position(9), 1);
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(position(9)));
    try std.testing.expectEqual(@as(u64, 1), s.imports.releaseResolutionHold(position(9)));
    s.imports.releaseSessionHeld(position(9), 1);
    try std.testing.expect(!s.holdsImport(position(9)));
}

test "a second hold keeps the retains until it leaves as well" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    s.imports.holdForResolution(position(9));
    s.imports.holdForResolution(position(9));
    try s.imports.decrement(position(9), 1);
    try std.testing.expectEqual(@as(u64, 0), s.imports.releaseResolutionHold(position(9)));
    try std.testing.expect(s.imports.heldByResolution(position(9)));
    try std.testing.expectEqual(@as(u64, 1), s.imports.releaseResolutionHold(position(9)));
}

test "a rolled back retain leaves a held row live and retires an unheld one" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    s.releaseImportRetain(position(9));
    try std.testing.expect(!s.holdsImport(position(9)));

    try s.registerImport(position(11));
    try s.registerImport(position(11));
    s.imports.holdForResolution(position(11));
    s.releaseImportRetain(position(11));
    try std.testing.expectEqual(@as(u64, 1), s.importRefcount(position(11)));
    try std.testing.expect(s.imports.heldByResolution(position(11)));
}

test "a Host handle lifted from a fully held-back row takes one retain back" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    s.imports.holdForResolution(position(9));
    try s.imports.decrement(position(9), 1);
    try std.testing.expectEqual(@as(u64, 0), s.importReleasable(position(9)));

    try s.noteHostCapability(position(9), 7);
    try std.testing.expectEqual(@as(u64, 1), s.importReleasable(position(9)));
    // The hold owes nothing: the handle's release is a caller's again.
    try std.testing.expectEqual(@as(u64, 0), s.imports.releaseResolutionHold(position(9)));
    try s.imports.decrement(position(9), 1);
    try std.testing.expect(!s.holdsImport(position(9)));
}

test "a release reaches the wire whole, not at all, or without its held entries" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    try s.registerImport(position(11));
    try s.registerImport(position(13));
    s.imports.holdForResolution(position(11));

    try std.testing.expectEqual(session.WireRelease.all, try s.wireRelease(allocator, .{ .positions = &.{ 9, 13 }, .deltas = &.{ 1, 1 } }));
    try std.testing.expectEqual(session.WireRelease.none, try s.wireRelease(allocator, .{ .positions = &.{11}, .deltas = &.{1} }));

    const some = try s.wireRelease(allocator, .{ .positions = &.{ 9, 11, 13 }, .deltas = &.{ 1, 1, 2 } });
    defer some.deinit(allocator);
    try std.testing.expectEqualSlices(u64, &.{ 9, 13 }, some.some.positions);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, some.some.deltas);
}

test "a stored value naming one import twice holds it twice and releases it once" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    try s.registerImport(position(9));
    const batch = (try session.ImportRelease.prepareForValue(&s, .{ .@"struct" = &.{
        .{ .key = "a", .value = .{ .reference = .{ .far = model.FarRef.object(9) } } },
        .{ .key = "b", .value = .{ .reference = .{ .far = model.FarRef.object(9) } } },
    } })).?;
    defer batch.destroy(&s);
    batch.take(&s);
    try std.testing.expectEqual(@as(u64, 2), s.imports.resolutionHolds(position(9)));

    try s.imports.decrement(position(9), 1);
    batch.settle(&s);
    try std.testing.expect(!s.imports.heldByResolution(position(9)));
    const release = batch.release();
    try std.testing.expectEqualSlices(u64, &.{9}, release.positions);
    try std.testing.expectEqualSlices(u64, &.{1}, release.deltas);
    s.imports.releaseSessionHeld(position(9), 1);
    try std.testing.expect(!s.holdsImport(position(9)));
}
