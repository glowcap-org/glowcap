//! Wire-delta GC emission for stateless capability hosts (ADR-0008).
//!
//! A host that does not retain imports introduced by an inbound deliver should
//! release them immediately via `op:gc-exports`. Likewise, once an outbound answer
//! is resolved the host may GC the answer-pos via `op:gc-answers`. This is
//! adapter policy — the session tables own the counts; these helpers only enqueue
//! the wire messages after a surfaced event has been handled.

const engine = @import("../engine/mod.zig");
const model = @import("../model/mod.zig");

const GcEntry = struct { pos: u64, delta: u64 };

/// Accumulates per-position wire-deltas for an outbound `op:gc-exports`. A single
/// legal deliver can introduce far more than a fixed buffer's worth of distinct
/// `far` positions, so rather than silently dropping the overflow (which would
/// strand the unreleased imports on both peers' tables), the accumulator flushes
/// a `gc-exports` message whenever the buffer fills and keeps going. Every
/// introduced position is therefore released; no allocation, just more messages.
const GcExportBatch = struct {
    peer: *engine.Peer,
    counts: [32]GcEntry = undefined,
    n: usize = 0,

    fn add(self: *GcExportBatch, pos: u64) void {
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
/// stateless host does not retain.
pub fn emitExportsForDeliver(peer: *engine.Peer, event: *engine.Event) void {
    const body = event.view() catch return;
    const deliver = switch (body) {
        .deliver => |d| d,
        else => return,
    };

    var batch = GcExportBatch{ .peer = peer };

    var it = deliver.args.iterator();
    while (it.next() catch null) |arg| {
        switch (arg) {
            .reference => |ref| switch (ref) {
                .far => |far| batch.add(far.import_id),
                else => {},
            },
            else => {},
        }
    }

    if (deliver.resolve_me_desc) |rmd| {
        switch (rmd) {
            .far => |far| batch.add(far.import_id),
            else => {},
        }
    }

    if (referencePosition(deliver.target)) |target| {
        if (peer.session_state.answerForResolverExport(target)) |answer| {
            const answer_positions = [_]u64{answer};
            peer.sendCopying(.{ .gc_answer = .{ .positions = &answer_positions } }) catch {};
        }
    }

    batch.flush();
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
    const positions = [_]u64{answer};
    peer.sendCopying(.{ .gc_answer = .{ .positions = &positions } }) catch {};
}

fn referencePosition(reference: model.view.Reference) ?u64 {
    return switch (reference) {
        .near => |near| near.export_id,
        .far => |far| far.import_id,
        .promise, .sturdy, .broken => null,
    };
}
