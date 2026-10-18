//! Trace local promise projections through the Session's existing owners.
//! Stamps preserve answer identity; they do not retain an internally chained
//! projection. This allocation-free mark/sweep supplies that lifetime without
//! strong reference cycles. Scratch lives in the existing resolver-purpose
//! union and never participates in its BiMap identity.
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const answers = @import("answers/store.zig");
const local_promise = @import("local_promise.zig");
const LocalPromiseAnswer = @import("promises/types.zig").LocalPromiseAnswer;

const Trace = struct {
    owner: *session.Session,
    /// The mark list's head. `.from(0)` is the empty list, as on `gc_next`.
    head: model.ExportPosition = .from(0),

    fn markExport(self: *Trace, position: model.ExportPosition) void {
        const purpose = self.owner.exports.purposePtr(position) orelse return;
        if (purpose.* != .local_promise_answer) return;
        const projection = &purpose.local_promise_answer;
        if (projection.gc_mark) return;
        projection.gc_mark = true;
        projection.gc_next = self.head;
        self.head = position;
    }

    fn markTarget(self: *Trace, target: answers.AnswerTarget) void {
        // A wire target's explicit release must stay released. Live wire and
        // detached rows are independently scanned roots, never resurrected.
        if (target.name != .virtual) return;
        const current = self.owner.answerTargetNamed(target.name) orelse return;
        if (current.row_id != target.row_id) return;
        const position = local_promise.projectionExport(self.owner, target.name) orelse return;
        self.markExport(position);
    }

    fn argument(self: *Trace, value: model.Argument) void {
        switch (value) {
            .reference => |reference| switch (reference) {
                .near => |near| self.markExport(near.export_position),
                else => {},
            },
            .list, .set => |items| for (items) |item| self.argument(item),
            .tagged => |tagged| for (tagged.value) |item| self.argument(item),
            .@"struct" => |entries| for (entries) |entry| self.argument(entry.value),
            else => {},
        }
    }

    fn stored(self: *Trace, resolution: *const answers.StoredResolution) void {
        if (resolution.promise_target) |target| self.markTarget(target);
        if (resolution.value == .fulfill) self.argument(resolution.value.fulfill);
    }

    fn payload(self: *Trace, value: *const answers.AnswerPayload) void {
        if (value.resolution) |*resolution| self.stored(resolution);
        // Accepted calls retain local capabilities even when the partner has
        // returned the wire mention from which its desc:export originated.
        for (value.queue.items) |call| switch (call.message) {
            .deliver => |deliver| for (deliver.args) |arg| self.argument(arg),
            else => {},
        };
    }

    fn drain(self: *Trace) void {
        while (self.head.int() != 0) {
            const position = self.head;
            const purpose = self.owner.exports.purposePtr(position) orelse unreachable;
            const projection = &purpose.local_promise_answer;
            self.head = projection.gc_next;
            projection.gc_next = .from(0);
            const row = self.owner.inbound_answers.getPtr(projection.name()) orelse unreachable;
            if (row.payload) |value| self.payload(value);
        }
    }
};

fn projectionAt(owner: *session.Session, position: model.ExportPosition) *LocalPromiseAnswer {
    const purpose = owner.exports.purposePtr(position) orelse unreachable;
    return &purpose.local_promise_answer;
}

/// A projection the partner or a local owner still holds directly. Only a
/// projection without such a root can be garbage. A settlement whose carrier
/// is still owed is a local producer root, like a staging owner.
fn selfRooted(owner: *session.Session, position: model.ExportPosition, projection: *const LocalPromiseAnswer) bool {
    if (projection.staging_owners != 0 or projection.settlement_deferred or owner.exports.wireHeld(position) != 0) return true;
    const row = owner.inbound_answers.getPtr(projection.name()) orelse unreachable;
    if (row.status() == .pending) return true;
    return if (row.payload) |value| value.hasConsequences() else false;
}

/// Trace each rooted tree and reachable projection once, then collect an
/// unrooted resolved component as a unit. Pending projections remain local
/// producer roots. No heap table or recursion across the promise graph exists;
/// value-tree recursion is bounded by the admission-time model depth check.
///
/// Every collection site is a release the partner can drive, so the scan of
/// the answer tables runs only when some projection lacks a root of its own. Otherwise tracing could reclaim nothing, and the cost is
/// one pass over the registry.
pub fn collect(owner: *session.Session) void {
    const registry = owner.local_promises orelse return;
    if (registry.state != .active) return;
    var candidate = false;
    for (registry.projections.items) |position| {
        const projection = projectionAt(owner, position);
        projection.gc_mark = false;
        projection.gc_next = .from(0);
        if (!selfRooted(owner, position, projection)) candidate = true;
    }
    if (!candidate) {
        if (registry.projections.items.len == 0) local_promise.destroyRegistry(owner);
        return;
    }

    var trace: Trace = .{ .owner = owner };
    for (registry.projections.items) |position| {
        if (selfRooted(owner, position, projectionAt(owner, position))) trace.markExport(position);
    }
    var rows = owner.inbound_answers.rows.iterator();
    while (rows.next()) |entry| {
        if (entry.key_ptr.* == .virtual and local_promise.isAnswer(owner, entry.key_ptr.*)) continue;
        if (entry.value_ptr.payload) |value| trace.payload(value);
    }
    if (owner.detached_inbound_answers) |detached| {
        var detached_rows = detached.rows.valueIterator();
        while (detached_rows.next()) |entry| trace.payload(entry.payload);
    }
    trace.drain();

    // The registry, not either table, drives the sweep, so removing a BiMap or
    // answer row cannot invalidate the walk.
    var kept: usize = 0;
    for (registry.projections.items) |position| {
        const projection = projectionAt(owner, position).*;
        if (projection.gc_mark) {
            registry.projections.items[kept] = position;
            kept += 1;
            continue;
        }
        std.debug.assert(owner.exports.clearPurpose(position) != null);
        owner.releaseUnsharedExport(position);
        const row = owner.inbound_answers.getPtr(projection.name()) orelse unreachable;
        owner.releaseInboundAnswerCell(row);
        owner.inbound_answers.remove(projection.name());
    }
    registry.projections.shrinkRetainingCapacity(kept);
    if (kept == 0) local_promise.destroyRegistry(owner);
}
