//! Wire-delta GC accounting and structural well-formedness checks (ADR-0008),
//! as stateless free functions over the tables and messages they validate.
//!
//! These hold no session authority: each takes the table (or just a message)
//! and answers a yes/no, or applies a pre-validated decrement. The session's
//! validate/apply spine (`validate.zig` / `apply.zig`) calls them, and they are
//! re-exported from `mod.zig` so a caller still writes `session.checkGcExportDecrement`.
//! Validators run a full pass before any `apply*` mutates, so apply stays atomic;
//! a host allocation failure is propagated as itself, never disguised as a
//! partner protocol violation.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Error = session.Error;
const AnswerTable = session.AnswerTable;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Reject an `op:gc-exports` whose cumulative deltas would drive any export /
/// import refcount below zero (or release an unknown id). Validates the whole
/// message before `applyGcExportDecrement` mutates, so apply stays atomic.
/// A host allocation failure is propagated as itself, never disguised as a
/// partner protocol violation.
/// `table` is whichever wire-delta refcount table the message releases: the
/// inbound `op:gc-exports` releases our exports, the outbound one releases our
/// imports, so this is generic over `ExportTable` / `ImportTable` — it reads
/// only `wireHeld` and never the cap. Validating against `wireHeld` rather
/// than `count` is load-bearing on the export side: an export row carries a
/// local baseline the wire never granted, so a hostile partner releasing one
/// more than it was ever sent must be refused loudly instead of deleting the
/// row (and with it our own live capability).
pub fn checkGcExportDecrement(
    allocator: std.mem.Allocator,
    table: anytype,
    gc_export: model.GcExport,
) (Error || std.mem.Allocator.Error)!void {
    // Single pass over the wire deltas (O(1) `count` per position with the
    // position-keyed table): accumulate each position's running total and
    // reject the moment it would exceed the live refcount. The scratch map
    // tolerates repeated positions in one message without the prior O(n^2)
    // re-scan; it is GC-validation scratch, freed before apply.
    // The bulk gc vectors carry raw wire `u64` positions; the typed table keys
    // on its own `Id` (export or import). Convert at this seam — the one place a
    // wire position becomes a typed id for the table it releases.
    const Id = @TypeOf(table.*).Id;
    var pending: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer pending.deinit(allocator);
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        // The bootstrap position is pinned outside wire-delta accounting
        // (`retainSentExports` never counts a mention of it), so a partner
        // releasing its bootstrap import — Goblins' import-0 will handler
        // emits exactly that — is a no-op, never an underflow and never the
        // death of the bootstrap export.
        if (pos == BOOTSTRAP_POSITION) continue;
        const gop = try pending.getOrPut(allocator, pos);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = std.math.add(u64, gop.value_ptr.*, delta) catch return Error.GcUnderflow;
        if (gop.value_ptr.* > table.wireHeld(Id.from(pos))) return Error.GcUnderflow;
    }
}

pub fn applyGcExportDecrement(table: anytype, gc_export: model.GcExport) Error!void {
    const Id = @TypeOf(table.*).Id;
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        // Pinned bootstrap position: skipped in validation, skipped here.
        if (pos == BOOTSTRAP_POSITION) continue;
        try table.decrement(Id.from(pos), delta);
    }
}

/// Reject an `op:gc-answers` whose per-id occurrence count exceeds the answer's
/// (single-reference) refcount, or that names an unknown answer-pos. Single pass
/// with O(1) per-position `count`; the scratch map folds repeated positions
/// without re-scanning the message. A host allocation failure is propagated as
/// itself, never disguised as a partner protocol violation.
pub fn checkGcAnswerDecrement(
    allocator: std.mem.Allocator,
    table: *const AnswerTable,
    positions: []const u64,
) (Error || std.mem.Allocator.Error)!void {
    var pending: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer pending.deinit(allocator);
    for (positions) |pos| {
        const gop = try pending.getOrPut(allocator, pos);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* > table.count(model.AnswerPosition.from(pos))) return Error.GcUnderflow;
    }
}

pub fn validateGcExport(gc_export: model.GcExport) Error!void {
    if (gc_export.positions.len != gc_export.deltas.len) {
        return Error.MalformedMessage;
    }
}

pub fn validateHandoffWellFormed(handoff: model.Handoff) Error!void {
    switch (handoff) {
        .give => |give| {
            if (give.gift_id.len == 0 or give.recipient_key.len == 0) {
                return Error.MalformedMessage;
            }
        },
        .receive => |receive| {
            if (receive.receiving_session.len == 0) return Error.MalformedMessage;
            if (receive.signed_give.gift_id.len == 0 or receive.signed_give.recipient_key.len == 0) {
                return Error.MalformedMessage;
            }
        },
    }
}
