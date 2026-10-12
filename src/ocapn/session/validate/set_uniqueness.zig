//! Set uniqueness for owned values and lazy borrowed sequences.
//!
//! Hashes select candidates. Only equality can refuse a duplicate. Every
//! confirmation shares the caller's per-message comparison allowance. A
//! deliberately colliding nested set can demand quadratic comparisons, so
//! exhaustion is a typed refusal rather than unbounded partner work.

const std = @import("std");
const model = @import("model");

const inline_capacity = 8;
const BorrowedRow = HashRow(model.view.Args.Checkpoint);
const OwnedRow = HashRow(usize);

fn HashRow(comptime Position: type) type {
    return struct {
        hash: u64,
        position: Position,
        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.hash < b.hash;
        }
    };
}

/// Store one hash/checkpoint row per member, not a full Argument view. Small
/// sets stay on the stack. Larger rows borrow the recv turn's arena. A unique
/// hash needs no further projection. Collisions reuse one view buffer sized
/// to the largest run, projecting each member once before comparison. Syrup
/// projection can scan nested bytes: caching avoids an unbudgeted scan per
/// pair, and the extra projection pass visits at most the set's wire region.
/// No member becomes an owned value. The caller resets scratch after the turn.
pub fn checkBorrowed(
    scratch: std.mem.Allocator,
    items: model.view.Args,
    budget: *model.equality.CompareBudget,
) (model.view.Error || error{ DuplicateSetElement, CompareBudgetExhausted, MalformedMessage })!void {
    const count = try items.len();
    if (count < 2) return;
    var stack_rows: [inline_capacity]BorrowedRow = undefined;
    const rows = if (count <= inline_capacity)
        stack_rows[0..count]
    else
        try scratch.alloc(BorrowedRow, count);
    var it = items.iterator();
    var initialized: usize = 0;
    while (true) {
        const checkpoint = it.checkpoint();
        const element = (try it.next()) orelse break;
        // Length and projection have separate codec implementations. Never
        // sort uninitialized rows or overrun the stack if they disagree.
        if (initialized >= count) return error.MalformedMessage;
        rows[initialized] = .{
            .hash = try model.equality.viewArgumentHash(element),
            .position = checkpoint,
        };
        initialized += 1;
    }
    if (initialized != count) return error.MalformedMessage;
    std.mem.sort(BorrowedRow, rows, {}, BorrowedRow.lessThan);

    var largest_run: usize = 1;
    var start: usize = 0;
    while (start < count) {
        const end = runEnd(rows, start);
        largest_run = @max(largest_run, end - start);
        start = end;
    }
    if (largest_run == 1) return;
    var stack_elements: [inline_capacity]model.view.Argument = undefined;
    const elements = if (largest_run <= inline_capacity)
        stack_elements[0..largest_run]
    else
        try scratch.alloc(model.view.Argument, largest_run);
    start = 0;
    while (start < count) {
        const end = runEnd(rows, start);
        const run = rows[start..end];
        if (run.len > 1) {
            for (run, 0..) |row, i| elements[i] = try items.atCheckpoint(row.position);
            for (elements[0..run.len], 0..) |element, i| {
                for (elements[0..i]) |prior| {
                    if (try model.equality.viewArgumentsEqualBounded(
                        prior,
                        element,
                        .{ .scratch = scratch, .budget = budget },
                    )) return error.DuplicateSetElement;
                }
            }
        }
        start = end;
    }
}

fn runEnd(rows: []const BorrowedRow, start: usize) usize {
    var end = start + 1;
    while (end < rows.len and rows[end].hash == rows[start].hash) : (end += 1) {}
    return end;
}

/// The owned-slice arm of the set-uniqueness fold, shared by the inbound
/// owned fallback above and the send-side walk (`validateArgument`). The
/// inbound path hands the recv arena (rows die in the turn reset). The send
/// path hands the session gpa (no recv turn brackets a send), so small sets
/// stay on the stack and a spilled row slice is freed here.
/// Confirming charges `budget` per element visit as the borrowed fold
/// does, both folds run the one comparison spine, so a partner-influenced
/// owned tree (a stored relayed resolution) buys bounded work, not trusted
/// work.
pub fn checkOwned(
    scratch: std.mem.Allocator,
    elements: []const model.Argument,
    budget: *model.equality.CompareBudget,
) error{ OutOfMemory, DuplicateSetElement, CompareBudgetExhausted }!void {
    if (elements.len < 2) return;
    var stack_rows: [inline_capacity]OwnedRow = undefined;
    const spilled = elements.len > inline_capacity;
    const rows: []OwnedRow = if (spilled)
        try scratch.alloc(OwnedRow, elements.len)
    else
        stack_rows[0..elements.len];
    defer if (spilled) scratch.free(rows);
    for (elements, 0..) |element, idx| {
        rows[idx] = .{ .hash = model.equality.argumentHash(element), .position = idx };
    }
    std.mem.sort(OwnedRow, rows, {}, OwnedRow.lessThan);
    var run_start: usize = 0;
    for (rows, 0..) |row, ri| {
        if (row.hash != rows[run_start].hash) run_start = ri;
        for (rows[run_start..ri]) |prior| {
            const equal = model.equality.argumentsEqualBounded(
                &elements[prior.position],
                &elements[row.position],
                .{ .scratch = scratch, .budget = budget },
            ) catch |err| switch (err) {
                // An owned tree projects slice-backed with `.projected` hints
                // (the owned-argument projection in `model.view`), so the
                // lazy-view failure arm cannot fire on it.
                error.MalformedView => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
                error.CompareBudgetExhausted => return error.CompareBudgetExhausted,
            };
            if (equal) return error.DuplicateSetElement;
        }
    }
}
