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

/// Unique positions a typical `op:gc-*` folds on the stack before spilling to a
/// heap map. Real releases are almost always one or a few positions; the map
/// exists only so an adversarial vector of many distinct ids still validates in
/// one pass without an O(n²) re-scan.
const fold_stack_cap = 8;

/// Scratch that folds repeated positions in one message: a fixed stack for the
/// common small case, then `AutoHashMapUnmanaged` once unique count exceeds the
/// stack. Freed before apply; recv callers feed the session's `recv_scratch`.
const PendingFold = struct {
    stack: [fold_stack_cap]Entry = undefined,
    stack_len: usize = 0,
    map: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    spilled: bool = false,

    const Entry = struct { pos: u64, total: u64 };

    fn deinit(self: *PendingFold, allocator: std.mem.Allocator) void {
        if (self.spilled) self.map.deinit(allocator);
    }

    /// Add `delta` into the running total for `pos`, returning the new total.
    /// Overflow of the u64 accumulator is `GcUnderflow` (same loud refusal the
    /// prior map path used). Spilling the stack into the map may return OOM.
    fn add(self: *PendingFold, allocator: std.mem.Allocator, pos: u64, delta: u64) (Error || std.mem.Allocator.Error)!u64 {
        if (!self.spilled) {
            for (self.stack[0..self.stack_len]) |*entry| {
                if (entry.pos == pos) {
                    entry.total = std.math.add(u64, entry.total, delta) catch return Error.GcUnderflow;
                    return entry.total;
                }
            }
            if (self.stack_len < fold_stack_cap) {
                self.stack[self.stack_len] = .{ .pos = pos, .total = delta };
                self.stack_len += 1;
                return delta;
            }
            try self.spill(allocator);
        }
        const gop = try self.map.getOrPut(allocator, pos);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = std.math.add(u64, gop.value_ptr.*, delta) catch return Error.GcUnderflow;
        return gop.value_ptr.*;
    }

    fn spill(self: *PendingFold, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.spilled = true;
        errdefer {
            self.map.deinit(allocator);
            self.map = .empty;
            self.spilled = false;
        }
        for (self.stack[0..self.stack_len]) |entry| {
            try self.map.put(allocator, entry.pos, entry.total);
        }
        self.stack_len = 0;
    }
};

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
    // reject the moment it would exceed the live refcount. The fold scratch
    // tolerates repeated positions in one message without an O(n²) re-scan;
    // typical small vectors stay on the stack, and only a many-unique spill
    // allocates. It is GC-validation scratch, freed before apply.
    // The bulk gc vectors carry raw wire `u64` positions; the typed table keys
    // on its own `Id` (export or import). Convert at this seam — the one place a
    // wire position becomes a typed id for the table it releases.
    const Id = @TypeOf(table.*).Id;
    var pending: PendingFold = .{};
    defer pending.deinit(allocator);
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        // The bootstrap position is pinned outside wire-delta accounting
        // (`retainSentExports` never counts a mention of it), so a partner
        // releasing its bootstrap import — Goblins' import-0 will handler
        // emits exactly that — is a no-op, never an underflow and never the
        // death of the bootstrap export.
        if (pos == BOOTSTRAP_POSITION) continue;
        const total = try pending.add(allocator, pos, delta);
        if (total > table.wireHeld(Id.from(pos))) return Error.GcUnderflow;
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
/// with O(1) per-position `count`; the fold scratch collapses repeated positions
/// without re-scanning the message. A host allocation failure is propagated as
/// itself, never disguised as a partner protocol violation.
pub fn checkGcAnswerDecrement(
    allocator: std.mem.Allocator,
    table: *const AnswerTable,
    positions: []const u64,
) (Error || std.mem.Allocator.Error)!void {
    var pending: PendingFold = .{};
    defer pending.deinit(allocator);
    for (positions) |pos| {
        const total = try pending.add(allocator, pos, 1);
        if (total > table.count(model.AnswerPosition.from(pos))) return Error.GcUnderflow;
    }
}

/// Enforce the operation's structural wire rules before any table authority is
/// consulted or mutated: the lists are parallel and every wire delta is positive.
pub fn validateGcExport(gc_export: model.GcExport) Error!void {
    if (gc_export.positions.len != gc_export.deltas.len) {
        return Error.MalformedMessage;
    }
    for (gc_export.deltas) |delta| {
        if (delta == 0) return Error.MalformedMessage;
    }
}

pub fn validateHandoffWellFormed(handoff: anytype) Error!void {
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
