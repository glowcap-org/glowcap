//! Distributed-GC reclamation gate: the session invariant the binding
//! finalizers drive (ADR-0025).
//!
//! Finalizer-driven GC rests on one session promise: an import row counted up by
//! a wire-lifted `far` reference is *fully reclaimed* when the matching
//! `op:gc-exports` delta brings it to zero (ADR-0004, `05-gc.md` GC-1). If a
//! released row were not reclaimed, a long session that lifts and drops many
//! imports, exactly what a binding's dropped-handle finalizer produces, would
//! grow the import table without bound, and the opt-in GC would trade a partner's
//! leak for a local one.
//!
//! This holds the importer half on a single session: churn distinct positions,
//! each `registerImport` standing for a far reference lifted from an inbound
//! message, each `recordSend(gc_export, delta 1)` standing for the one unit a
//! dropped handle releases. Only one import is ever live at a time, so a session
//! that reclaims rows holds flat heap across the whole churn. One that strands
//! them grows linearly. The per-handle-equals-one-unit accounting (ADR-0025) is
//! what makes the matching delta exact.

const std = @import("std");
const glowcap = @import("glowcap");

const session = glowcap.ocapn.session;
const LiveBytesAllocator = @import("../support/alloc_metrics.zig").LiveBytesAllocator;

test "finalizer-driven gc-export churn reclaims import rows and holds flat heap" {
    const backing = std.testing.allocator;
    var tracker = LiveBytesAllocator{ .backing = backing };
    const tracked = tracker.allocator();

    var s = session.Session.init(tracked);
    defer s.deinit();

    // Warm one import/release pair so the table backing reaches steady capacity
    // before the measured churn, the same warmed-baseline shape the footprint
    // budget uses, so the quotient is the marginal cost, not first-allocation.
    try s.registerImport(.from(1));
    try s.recordSend(.{ .gc_export = .{ .positions = &.{1}, .deltas = &.{1} } });

    const before = tracker.liveBytes();

    const churn: u64 = 100_000;
    var pos: u64 = 2;
    while (pos < churn) : (pos += 1) {
        // A far reference lifted from the wire: the session counts the import up.
        try s.registerImport(.from(pos));
        try std.testing.expectEqual(@as(u64, 1), s.importRefcount(.from(pos)));
        // The dropped handle's finalizer releases exactly one wire-count unit.
        try s.recordSend(.{ .gc_export = .{ .positions = &.{pos}, .deltas = &.{1} } });
        try std.testing.expect(!s.hasImport(.from(pos)));
    }

    const after = tracker.liveBytes();

    // Only one import is live at any moment, so a session that reclaims released
    // rows grows by at most the table's steady backing, never one row per
    // churned position. A linear leak would blow far past this.
    const grown = after - before;
    if (grown > 4096) {
        std.debug.print(
            "gc reclamation regression: {d} import/release pairs grew live heap by {d} B — released rows are not reclaimed\n",
            .{ churn - 2, grown },
        );
        return error.ImportRowsNotReclaimed;
    }
}
