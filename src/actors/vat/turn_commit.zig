//! What an outermost turn holds until it returns: its local sends (ADR-0058)
//! and the participants that recorded far effects (ADR-0058).
//!
//! `ingress.zig` stages a send made inside a turn with its admission charged
//! and its vow minted, outside every queue. A turn that returns successfully
//! splices the staged sends onto their queues and commits each participant. A
//! failed turn aborts each participant in reverse before notifying observers
//! and dropping its local sends.

const std = @import("std");
const vat_mod = @import("mod.zig");
const ingress_mod = @import("ingress.zig");

const Vat = vat_mod.Vat;

/// Commit the running outermost turn's staged sends. Called inside that turn's
/// frame, before its reply leaves it. Splicing runs no application code and
/// cannot fail.
pub fn commit(vat: *Vat) void {
    std.debug.assert(vat.turn_depth == 1);
    for (vat.staged.items) |entry| ingress_mod.commitStaged(vat, entry);
    vat.staged.clearRetainingCapacity();
    for (vat.participants.items) |participant| participant.commit(participant.ctx, vat);
    vat.participants.clearRetainingCapacity();
    vat.turn_break_reservations = 0;
    trimBreaks(vat);
}

/// One answer slot per answered far send in this turn. Admission reserves
/// before publication so capturing a failure notification cannot allocate.
/// Holding callbacks until
/// all effects are undone prevents a reentrant turn from committing another
/// participant's failed work. The Vat shares this buffer across Ports and keeps
/// at most steady_list_bytes after the turn. No per-session buffer is added.
pub fn reserveBreak(vat: *Vat) vat_mod.Error!void {
    const count = vat.turn_break_reservations + 1;
    try vat.turn_breaks.ensureTotalCapacity(vat.allocator, count);
    vat.turn_break_reservations = count;
}

fn trimBreaks(vat: *Vat) void {
    std.debug.assert(vat.turn_breaks.items.len == 0);
    if (vat.turn_breaks.capacity > vat_mod.steady_list_bytes / @sizeOf(vat_mod.TurnBreak))
        vat.turn_breaks.clearAndFree(vat.allocator);
}

/// Drop a failed outermost turn's staged sends and break their vows with
/// `reason`. Called after the frame closed, so listeners run at depth zero and
/// any send they make goes onto a queue directly.
pub fn drop(vat: *Vat, reason: []const u8) void {
    std.debug.assert(vat.turn_depth == 0);
    // Detach every effect list before callbacks. A broken send's listener may
    // run a new turn, which must never commit the failed turn's participants.
    var staged = vat.staged;
    vat.staged = .empty;
    var participants = vat.participants;
    vat.participants = .empty;
    defer participants.deinit(vat.allocator);
    var i = participants.items.len;
    while (i != 0) {
        i -= 1;
        const participant = participants.items[i];
        participant.abort(participant.ctx, vat, reason);
    }
    var breaks = vat.turn_breaks;
    vat.turn_breaks = .empty;
    vat.turn_break_reservations = 0;
    i = participants.items.len;
    while (i != 0) {
        i -= 1;
        const participant = participants.items[i];
        if (participant.abort_notify) |notify| notify(participant.ctx, vat, reason);
    }
    for (breaks.items) |pending| pending.port.breakRetracted(pending.answer, reason);
    breaks.clearRetainingCapacity();
    keepLarger(vat_mod.TurnBreak, vat, &vat.turn_breaks, &breaks);
    trimBreaks(vat);
    for (staged.items) |entry| ingress_mod.dropStaged(vat, entry, reason);
    staged.clearRetainingCapacity();
    keepLarger(ingress_mod.StagedIngress, vat, &vat.staged, &staged);
}

/// Keep whichever of the vat's list and the emptied `detached` list has the
/// larger backing, so a callback that regrew the vat's list during the drop
/// never shrinks the retained capacity.
fn keepLarger(comptime T: type, vat: *Vat, live: *std.ArrayListUnmanaged(T), detached: *std.ArrayListUnmanaged(T)) void {
    if (live.capacity >= detached.capacity) {
        detached.deinit(vat.allocator);
    } else {
        live.deinit(vat.allocator);
        live.* = detached.*;
    }
}

/// Free staged sends without settling them, for a Vat torn down mid-turn.
pub fn discard(vat: *Vat) void {
    for (vat.staged.items) |entry| ingress_mod.discardStaged(vat, entry);
    vat.staged.deinit(vat.allocator);
}
