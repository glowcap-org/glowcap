//! Wire-delta GC emission for stateless capability hosts (ADR-0004).
//!
//! A host that does not retain imports introduced by an inbound deliver should
//! release them immediately via `op:gc-exports`. Likewise, once an outbound
//! answer is resolved the host may collect its wire question or local listen
//! record. This is adapter policy; the session tables own identity and counts.
//! Collection prepares before serving and releases after callbacks return.
//!
//! One exception to "the vat did not retain it, so nobody did": an event the
//! before-serve hook *claimed* never reaches the vat, and the node may have
//! retained something from it. A proxy home-listener fire that settles to a
//! capability is the live case: Host projection transfers a retain into the
//! Node's inline-Passable batch owner, which deposits it after the embedder
//! answers `need_gift_id`. Releasing the claimed observation on the way out of
//! that same turn would gc the gift from under its own deposit.
//! `Served.serveEvent` therefore emits stateless GC only after events that
//! reached the vat. A hook-claimed event keeps its observations under the hook
//! owner's policy.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");
const foundation = @import("foundation");

const GcEntry = struct { pos: u64, delta: u64 };

/// Accumulates per-position wire-deltas for an outbound `op:gc-exports`. A single
/// legal deliver can introduce far more than a fixed buffer's worth of distinct
/// `far` positions, so rather than silently dropping the overflow (which would
/// strand the unreleased imports on both peers' tables), the accumulator flushes
/// a `gc-exports` message whenever the buffer fills and keeps going. A full
/// buffer therefore costs more messages, never an allocation. An enqueue or
/// fallback-decode failure propagates through the event-serving boundary: a
/// consumed event must never strand an unreported release until teardown.
const GcExportBatch = struct {
    peer: *engine.Peer,
    counts: [32]GcEntry = undefined,
    n: usize = 0,

    fn add(self: *GcExportBatch, pos: u64) !void {
        // The bootstrap import is never accounted, the session's install walk
        // excludes it the same way, and an `op:gc-exports` naming it is refused
        // by send validation, which would strand the whole flush it rode in.
        if (pos == engine.bootstrap_position) return;
        for (self.counts[0..self.n]) |*entry| {
            if (entry.pos == pos) {
                entry.delta += 1;
                return;
            }
        }
        if (self.n == self.counts.len) try self.flush();
        self.counts[self.n] = .{ .pos = pos, .delta = 1 };
        self.n += 1;
    }

    fn flush(self: *GcExportBatch) !void {
        if (self.n == 0) return;
        var positions: [32]u64 = undefined;
        var deltas: [32]u64 = undefined;
        for (0..self.n) |j| {
            positions[j] = self.counts[j].pos;
            deltas[j] = self.counts[j].delta;
        }
        try self.peer.sendBorrowed(.{ .gc_export = .{
            .positions = positions[0..self.n],
            .deltas = deltas[0..self.n],
        } });
        self.n = 0;
    }
};

/// After an inbound deliver is dispatched, emit `op:gc-exports` for every `far`
/// reference its application arguments introduced that this stateless host does
/// not retain. A V1.0 resolver descriptor belongs to the answer until its
/// callback and is released beside that callback, not by event GC. When the
/// event carries `introduced_far_imports` (the session's own validate walk,
/// `session.validate.IntroducedImports`, threaded here by
/// `engine.inbound.dispatchOwnedFrame`), that record is reused instead
/// of re-walked. Absent (a deliver surfaced by a path other than the engine's
/// own inbound dispatch, such as a drained pipelined call redirected locally),
/// this falls back to the args walk below, which recurses through lists, sets,
/// tagged values, and structs (the same shape the session's import-install walk
/// takes), so a nested introduction's refcount is released like a top-level one
/// and the wire-delta accounting balances either way.
fn emitExportsForDeliver(peer: *engine.Peer, event: *engine.Event) !void {
    const body = event.view();
    const deliver = switch (body.*) {
        .deliver => |d| d,
        else => return,
    };

    var batch = GcExportBatch{ .peer = peer };

    if (event.introduced_far_imports) |mentions| {
        for (mentions) |import_position| try batch.add(import_position.int());
    } else {
        const max_depth = peer.limits().max_nesting_depth;
        try addIntroducedFarsInArgs(&batch, deliver.args, 0, max_depth);
    }

    try batch.flush();
}

/// Everything the introduced-far walk can refuse. The walk is recursive, so
/// its set is spelled from the non-recursive steps it takes.
const IntroducedFarsError = model.view.ProjectError || foundation.error_sets.Of(GcExportBatch.add);

/// One pass over a borrowed argument list, feeding every introduced `far` into
/// the batch. An iterator decode error propagates rather than silently ending
/// the walk. Depth past the session's already-validated nesting limit remains a
/// defensive stop.
fn addIntroducedFarsInArgs(batch: *GcExportBatch, args: model.view.Args, depth: usize, max_depth: usize) IntroducedFarsError!void {
    if (depth > max_depth) return;
    var it = args.iterator();
    while (try it.next()) |arg| try addIntroducedFars(batch, arg, depth, max_depth);
}

fn addIntroducedFars(batch: *GcExportBatch, arg: model.view.Argument, depth: usize, max_depth: usize) IntroducedFarsError!void {
    switch (arg) {
        .reference => |ref| switch (ref) {
            .far => |far| try batch.add(far.import_position.int()),
            else => {},
        },
        .list, .set => |items| try addIntroducedFarsInArgs(batch, items, depth + 1, max_depth),
        .tagged => |tagged| try addIntroducedFarsInArgs(batch, tagged.value, depth + 1, max_depth),
        .@"struct" => |entries| try addIntroducedFarsInStruct(batch, entries, depth + 1, max_depth),
        // Exhaustive, mirroring the session's install walk: a new Argument arm
        // must decide here whether it can carry a reference.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

fn addIntroducedFarsInStruct(batch: *GcExportBatch, entries: model.view.StructEntries, depth: usize, max_depth: usize) IntroducedFarsError!void {
    if (depth > max_depth) return;
    var it = entries.iterator();
    while (try it.next()) |entry| try addIntroducedFars(batch, entry.value, depth, max_depth);
}

/// Collect the event's exact answer identities with bounded stack storage.
/// A long alias list emits more batches instead of allocating a temporary
/// vector. A send refusal propagates after any preceding batches committed;
/// the consumed event's serving boundary owns terminal failure.
fn emitAnswerForResolve(peer: *engine.Peer, event: *engine.Event) !void {
    var positions: [32]u64 = undefined;
    var count: usize = 0;
    const aliases = event.resolveAliases();
    for (0..aliases.len + 1) |index| {
        const answer = if (index == 0) event.resolveTarget() else aliases[index - 1];
        if (try releaseWithoutWire(peer, answer)) continue;
        positions[count] = answer.position.int();
        count += 1;
        if (count == positions.len) {
            try peer.sendBorrowed(.{ .gc_answer = .{ .positions = positions[0..count] } });
            count = 0;
        }
    }
    if (count != 0)
        try peer.sendBorrowed(.{ .gc_answer = .{ .positions = positions[0..count] } });
}

/// Leave application-owned answers to their owner; retire unclaimed local
/// listen records here. Only an unclaimed wire question needs a GC frame.
fn releaseWithoutWire(peer: *engine.Peer, answer: engine.OutboundAnswerTarget) !bool {
    // Preparation proved the identity before serving. A callback may have
    // retired it or reused its position; neither gives GC a new obligation.
    const row = peer.session_state.outbound_answers.live(answer) orelse return true;
    if (row.application_release_claimed) return true;
    if (peer.session_state.outbound_answers.isQuestion(answer.position)) return false;
    try peer.session_state.releaseOutboundAnswer(answer.position);
    return true;
}

/// A collection turn borrows the event across serving. Resolve identities
/// must be live before callbacks run; afterwards an owner may have retired
/// them synchronously. Keeping that distinction here rejects stale input
/// without collecting an answer twice or touching a reused position.
pub const Collection = struct {
    peer: *engine.Peer,
    event: *engine.Event,

    pub fn prepare(peer: *engine.Peer, event: *engine.Event) error{GcUnderflow}!Collection {
        if (event.kind() == .resolve) {
            if (!peer.session_state.hasLiveOutboundAnswer(event.resolveTarget())) return error.GcUnderflow;
            for (event.resolveAliases()) |alias| {
                if (!peer.session_state.hasLiveOutboundAnswer(alias)) return error.GcUnderflow;
            }
        }
        return .{ .peer = peer, .event = event };
    }

    pub fn finish(self: Collection) !void {
        switch (self.event.kind()) {
            .deliver => try emitExportsForDeliver(self.peer, self.event),
            .resolve => try emitAnswerForResolve(self.peer, self.event),
            else => {},
        }
    }
};
