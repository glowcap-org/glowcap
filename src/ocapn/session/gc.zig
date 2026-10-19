//! Wire-delta GC accounting and structural well-formedness checks (ADR-0008),
//! as stateless free functions over the tables and messages they validate.
//!
//! These hold no session authority: each takes the table (or just a message)
//! and answers a yes/no, or applies a pre-validated decrement. The session's
//! validate/apply spine (`validate.zig` / `apply.zig`) calls them, and they are
//! re-exported from `mod.zig` so a caller still writes `session.checkGcExportDecrement`.
//! Validators run a full pass before any `apply*` mutates, so apply stays atomic.
//! A host allocation failure is propagated as itself, never disguised as a
//! partner protocol violation.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("mod.zig");

const Error = session.Error;
const bootstrap_position = session.bootstrap_position;

/// Scratch that folds repeated positions in one message. Real releases are
/// almost always one or a few positions, which stay inside the record. The
/// map behind it exists so an adversarial vector of many distinct ids still
/// validates in one pass without an O(n²) re-scan. Freed before apply. Recv
/// callers feed the session's `recv_scratch`.
const PendingFold = foundation.inline_rows.Table(u64, u64, 8, .wire);

/// Add `delta` into the running total for `pos`, returning the new total.
/// Overflow of the u64 accumulator is `GcOverflow`. Spilling the record into
/// its map may return OOM.
fn foldDelta(pending: *PendingFold, allocator: std.mem.Allocator, pos: u64, delta: u64) (Error || std.mem.Allocator.Error)!u64 {
    const row = try pending.getOrPut(allocator, pos);
    if (!row.found_existing) row.value_ptr.* = 0;
    row.value_ptr.* = std.math.add(u64, row.value_ptr.*, delta) catch return error.GcOverflow;
    return row.value_ptr.*;
}

/// Reject an `op:gc-exports` whose cumulative deltas would drive any export /
/// import refcount below zero (or release an unknown id). Validates the whole
/// message before `applyGcExportDecrement` mutates, so apply stays atomic.
/// A host allocation failure is propagated as itself, never disguised as a
/// partner protocol violation.
/// `table` is whichever wire-delta refcount table the message releases: the
/// inbound `op:gc-exports` releases our exports, the outbound one releases our
/// imports, so this is generic over `ExportTable` / `ImportTable`, it reads
/// only `releasable` and never the cap. Validating against `releasable` rather
/// than `count` matters on both sides. An export row carries a local
/// baseline the wire never granted, so an untrusted peer releasing one more
/// than it was ever sent must be refused loudly instead of deleting the row
/// (and with it our own live capability). An import row may carry retains the
/// session keeps for a release of its own, a linked V1.0 resolver's, a
/// pending listener's, a stable shortening edge's, and a caller releasing
/// past that remainder is the same defect refused the same way, so a pending
/// settlement can never address a row the partner was told is gone.
pub fn checkGcExportDecrement(
    allocator: std.mem.Allocator,
    table: anytype,
    gc_export: model.GcExport,
    wire_hash_multiplier: u64,
) (Error || std.mem.Allocator.Error)!void {
    // Single pass over the wire deltas (O(1) `count` per position with the
    // position-keyed table): accumulate each position's running total and
    // reject the moment it would exceed the live refcount. The fold scratch
    // tolerates repeated positions in one message without an O(n²) re-scan;
    // typical small vectors stay on the stack, and only a many-unique spill
    // allocates. It is GC-validation scratch, freed before apply.
    // The bulk gc vectors carry raw wire `u64` positions; the typed table keys
    // on its own `Id` (export or import). Convert at this seam, the one place a
    // wire position becomes a typed id for the table it releases.
    const Id = @TypeOf(table.*).Id;
    // The positions are the peer's words even when the table is ours.
    var pending: PendingFold = .keyed(wire_hash_multiplier);
    defer pending.deinit(allocator);
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        // The bootstrap position is pinned outside send-side export accounting,
        // so a partner
        // releasing its bootstrap import, Goblins' import-0 will handler
        // emits exactly that, is a no-op, never an underflow and never the
        // death of the bootstrap export.
        if (pos == bootstrap_position) continue;
        const total = try foldDelta(&pending, allocator, pos, delta);
        if (total > table.releasable(Id.from(pos))) return error.GcUnderflow;
    }
}

pub fn applyGcExportDecrement(table: anytype, gc_export: model.GcExport) Error!void {
    const Id = @TypeOf(table.*).Id;
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        // Pinned bootstrap position: skipped in validation, skipped here.
        if (pos == bootstrap_position) continue;
        try table.decrement(Id.from(pos), delta);
    }
}

/// Reject an `op:gc-answers` whose per-id occurrence count exceeds the answer's
/// (single-reference) refcount, or that names an unknown answer-pos. Single pass
/// with O(1) per-position `count`. The fold scratch collapses repeated positions
/// without re-scanning the message. A host allocation failure is propagated as
/// itself, never disguised as a partner protocol violation.
pub fn checkGcAnswerDecrement(
    allocator: std.mem.Allocator,
    table: anytype,
    positions: []const u64,
    wire_hash_multiplier: u64,
) (Error || std.mem.Allocator.Error)!void {
    var pending: PendingFold = .keyed(wire_hash_multiplier);
    defer pending.deinit(allocator);
    for (positions) |pos| {
        const total = try foldDelta(&pending, allocator, pos, 1);
        const Id = @TypeOf(table.*).Id;
        const id: Id = if (Id == model.AnswerName)
            .fromWire(.from(pos))
        else
            .from(pos);
        if (total > table.count(id)) return error.GcUnderflow;
    }
}

/// Enforce the operation's structural wire rules before any table authority is
/// consulted or mutated: the lists are parallel and every wire delta is positive.
pub fn validateGcExport(gc_export: model.GcExport) Error!void {
    if (gc_export.positions.len != gc_export.deltas.len) {
        return error.MalformedMessage;
    }
    for (gc_export.deltas) |delta| {
        if (delta == 0) return error.MalformedMessage;
    }
}

pub fn validateHandoffWellFormed(handoff: anytype) Error!void {
    switch (handoff) {
        .give => |give| {
            if (give.gift_id.len == 0 or give.recipient_key.len == 0) {
                return error.MalformedMessage;
            }
        },
        .receive => |receive| {
            if (receive.receiving_session.len == 0) return error.MalformedMessage;
            if (receive.signed_give.gift_id.len == 0 or receive.signed_give.recipient_key.len == 0) {
                return error.MalformedMessage;
            }
        },
    }
}
