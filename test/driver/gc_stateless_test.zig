//! Stateless-GC emission balance (ADR-0008): the driver's post-event
//! `op:gc-exports` walk must release exactly what the session's import-install
//! walk recorded. The install walk recurses through nested argument trees, so
//! the emission walk must too, a top-level-only walk strands every nested
//! introduction's refcount until teardown.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const driver = pancake.driver;

test "stateless GC releases a far introduced inside a nested argument" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p2 hosts the deliver target; p1 holds it as an import.
    try p1.session_state.registerImport(.from(1));
    try p2.session_state.registerExport(.from(1));
    // p1 hosts the object it introduces inside the nested arg — a reservation
    // whose first marshal below is what grants it.
    try p1.session_state.reserveExport(.from(7));

    // The deliver's args nest the introduction one level down, a list holding
    // p1's export 7, decoded by p2 (post perspective-flip) as the introduced
    // import 7.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(1) } },
        .args = &.{
            .{ .list = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }} },
        },
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    // p1's export 7 now carries two refs: the reserved baseline plus the wire
    // mention the partner owes a release for.
    try std.testing.expectEqual(@as(u64, 2), p1.session_state.exports.count(.from(7)));
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // The session installed the nested introduction.
    try std.testing.expect(p2.session_state.hasImport(.from(7)));

    {
        var event = p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
        driver.core.emitStatelessAfter(&p2, &event);
    }

    // The emission released the nested import on p2's own table.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(!p2.session_state.hasImport(.from(7)));

    // And the wire half balances: the release returns exactly the mention's
    // ref, leaving p1's export held by its local baseline alone.
    const gc_frame = p2.takeOutbound().?;
    try p1.feedOwned(gc_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(@as(u64, 1), p1.session_state.exports.count(.from(7)));
}
