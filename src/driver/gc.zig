//! Wire-delta GC emission for stateless capability hosts (ADR-0008).
//!
//! A host that does not retain imports introduced by an inbound deliver should
//! release them immediately via `op:gc-exports`. Likewise, once an outbound answer
//! is resolved the host may GC the answer-pos via `op:gc-answers`. This is
//! adapter policy, the session tables own the counts; these helpers only enqueue
//! the wire messages after a surfaced event has been handled.

const engine = @import("engine");
const model = @import("model");

const GcEntry = struct { pos: u64, delta: u64 };

/// Accumulates per-position wire-deltas for an outbound `op:gc-exports`. A single
/// legal deliver can introduce far more than a fixed buffer's worth of distinct
/// `far` positions, so rather than silently dropping the overflow (which would
/// strand the unreleased imports on both peers' tables), the accumulator flushes
/// a `gc-exports` message whenever the buffer fills and keeps going. A full
/// buffer therefore costs more messages, never an allocation. Emission is
/// best-effort: each flush's enqueue failure is swallowed, and a release that
/// failed to enqueue is stranded until session teardown reclaims the tables.
const GcExportBatch = struct {
    peer: *engine.Peer,
    counts: [32]GcEntry = undefined,
    n: usize = 0,

    fn add(self: *GcExportBatch, pos: u64) void {
        // The bootstrap import is never accounted, the session's install walk
        // excludes it the same way, and an `op:gc-exports` naming it is refused
        // by send validation, which would strand the whole flush it rode in.
        if (pos == engine.BOOTSTRAP_POSITION) return;
        for (self.counts[0..self.n]) |*entry| {
            if (entry.pos == pos) {
                entry.delta += 1;
                return;
            }
        }
        if (self.n == self.counts.len) self.flush();
        self.counts[self.n] = .{ .pos = pos, .delta = 1 };
        self.n += 1;
    }

    fn flush(self: *GcExportBatch) void {
        if (self.n == 0) return;
        var positions: [32]u64 = undefined;
        var deltas: [32]u64 = undefined;
        for (0..self.n) |j| {
            positions[j] = self.counts[j].pos;
            deltas[j] = self.counts[j].delta;
        }
        self.peer.sendCopying(.{ .gc_export = .{
            .positions = positions[0..self.n],
            .deltas = deltas[0..self.n],
        } }) catch {};
        self.n = 0;
    }
};

/// After an inbound deliver is dispatched, emit `op:gc-exports` for every `far`
/// reference the deliver's args (and `resolve_me_desc`) introduced that this
/// stateless host does not retain. The args walk recurses through lists, sets,
/// tagged values, and structs — the same shape the session's import-install
/// walk takes — so a nested introduction's refcount is released exactly like a
/// top-level one and the wire-delta accounting balances.
pub fn emitExportsForDeliver(peer: *engine.Peer, event: *engine.Event) void {
    const body = event.view() catch return;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return,
    };

    var batch = GcExportBatch{ .peer = peer };

    const max_depth = peer.session_state.limits.max_nesting_depth;
    addIntroducedFarsInArgs(&batch, deliver.args, 0, max_depth);

    if (deliver.resolve_me_desc) |rmd| {
        switch (rmd) {
            .far => |far| batch.add(far.import_position.int()),
            else => {},
        }
    }

    // Only a `.near` export this peer hosts can be a resolver export; a
    // partner-named `.far` import id in the same integer space must not key the
    // export-indexed resolver-answer lookup.
    if (deliver.target.exportPosition()) |target| {
        if (peer.session_state.answerForResolverExport(target)) |answer| {
            const answer_positions = [_]u64{answer.int()};
            peer.sendCopying(.{ .gc_answer = .{ .positions = &answer_positions } }) catch {};
        }
    }

    batch.flush();
}

/// One pass over a borrowed argument list, feeding every introduced `far` into
/// the batch. Best-effort like the emission itself: an iterator decode error
/// ends the walk early, and depth past the session's nesting limit (already
/// enforced at validation; this mirror is defensive) stops the recursion.
fn addIntroducedFarsInArgs(batch: *GcExportBatch, args: model.view.Args, depth: usize, max_depth: usize) void {
    if (depth > max_depth) return;
    var it = args.iterator();
    while (it.next() catch null) |arg| addIntroducedFars(batch, arg, depth, max_depth);
}

fn addIntroducedFars(batch: *GcExportBatch, arg: model.view.Argument, depth: usize, max_depth: usize) void {
    switch (arg) {
        .reference => |ref| switch (ref) {
            .far => |far| batch.add(far.import_position.int()),
            else => {},
        },
        .list, .set => |items| addIntroducedFarsInArgs(batch, items, depth + 1, max_depth),
        .tagged => |tagged| addIntroducedFarsInArgs(batch, tagged.value, depth + 1, max_depth),
        .@"struct" => |entries| addIntroducedFarsInStruct(batch, entries, depth + 1, max_depth),
        // Exhaustive on purpose, mirroring the session's install walk: a new
        // Argument arm must decide here whether it can carry a reference.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

fn addIntroducedFarsInStruct(batch: *GcExportBatch, entries: model.view.StructEntries, depth: usize, max_depth: usize) void {
    if (depth > max_depth) return;
    var it = entries.iterator();
    while (it.next() catch null) |entry| addIntroducedFars(batch, entry.value, depth, max_depth);
}

/// After a semantic resolve event, emit `op:gc-answers` for the settled answer-pos.
pub fn emitAnswerForResolve(peer: *engine.Peer, event: *engine.Event) void {
    if (event.kind() != .resolve) return;
    const answer = event.resolve_answer orelse blk: {
        const body = event.view() catch return;
        const resolve = switch (body) {
            .resolve => |r| r,
            else => return,
        };
        break :blk resolve.answer;
    };
    const positions = [_]u64{answer.int()};
    peer.sendCopying(.{ .gc_answer = .{ .positions = &positions } }) catch {};
}

/// The stateless-GC policy after one served event: a deliver gc-collects the
/// exports it introduced, a resolve gc-collects its settled answer. The single
/// home for which event kind triggers which emit, both the per-connection
/// `ConnectedVat` and the `LoopHost` fan-out call this so the policy cannot drift
/// between them.
pub fn emitStatelessAfter(peer: *engine.Peer, event: *engine.Event) void {
    switch (event.kind()) {
        .deliver => emitExportsForDeliver(peer, event),
        .resolve => emitAnswerForResolve(peer, event),
        else => {},
    }
}
