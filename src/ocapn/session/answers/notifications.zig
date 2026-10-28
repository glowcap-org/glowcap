//! Stable answer-notification ownership across `op:gc-answers` and position
//! reuse. The answer table owns pipelining. This module owns the independently
//! accepted resolver/listener obligation and its one stored resolution.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const answers = @import("store.zig");
const lifecycle = @import("lifecycle.zig");
const session = @import("../mod.zig");
const local_promise = @import("../local_promise.zig");

const Session = session.Session;

pub const Settlement = struct {
    target: answers.AnswerTarget,
    payload: *answers.AnswerPayload,
};

pub fn answerTargetNamed(self: *Session, name: model.AnswerName) ?answers.AnswerTarget {
    const row = self.inbound_answers.getPtr(name) orelse return null;
    return .{ .name = name, .row_id = row.row_id };
}

fn targetEql(a: answers.AnswerTarget, b: answers.AnswerTarget) bool {
    return a.row_id == b.row_id and std.meta.eql(a.name, b.name);
}

fn livePayload(self: *Session, target: answers.AnswerTarget) ?*answers.AnswerPayload {
    const row = self.inbound_answers.getPtr(target.name) orelse return null;
    if (row.row_id != target.row_id) return null;
    return row.payload;
}

fn detachedPayload(self: *Session, target: answers.AnswerTarget) ?*answers.AnswerPayload {
    const store = self.detached_inbound_answers orelse return null;
    const row = store.rows.get(target.row_id) orelse return null;
    if (!targetEql(row.target, target)) return null;
    return row.payload;
}

pub fn payload(self: *Session, target: answers.AnswerTarget) ?*answers.AnswerPayload {
    return livePayload(self, target) orelse detachedPayload(self, target);
}

/// Every inbound answer obligation still owned by the session. Wire-name GC
/// moves accepted work from the live table to the detached store, so both
/// stores spend the one inbound-answer budget.
pub fn obligationCount(self: *const Session) usize {
    const detached = if (self.detached_inbound_answers) |store| store.rows.count() else 0;
    return std.math.add(usize, self.inbound_answers.len(), detached) catch
        std.math.maxInt(usize);
}

fn prepareDetachedCapacity(self: *Session, additional: u32) !void {
    if (additional == 0) return;
    if (self.detached_inbound_answers) |store| {
        try store.rows.ensureUnusedCapacity(self.allocator, additional);
        return;
    }
    const store = try self.allocator.create(answers.DetachedAnswerStore);
    errdefer self.allocator.destroy(store);
    store.* = .{ .rows = .keyed(self.wire_hash_multiplier) };
    errdefer store.rows.deinit(self.allocator);
    try store.rows.ensureUnusedCapacity(self.allocator, additional);
    self.detached_inbound_answers = store;
}

/// Preflight every allocation a GC batch can need before decrementing one
/// answer. Attaching an empty payload is ownership-neutral. The authoritative
/// counts, links, and rows remain unchanged if a later allocation refuses.
pub fn prepareGc(self: *Session, positions: []const u64) !void {
    // A release names one or a few answers, so both records below hold
    // their rows in place and touch the arena only for a long vector. The
    // positions are the peer's words.
    const scratch = self.recv_scratch.allocator();
    var decrements: foundation.inline_rows.Table(u64, u64, 8, .wire) = .keyed(self.wire_hash_multiplier);
    defer decrements.deinit(scratch);
    try decrements.ensureUnusedCapacity(scratch, positions.len);
    for (positions) |position| {
        const entry = decrements.getOrPutAssumeCapacity(position);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* = std.math.add(u64, entry.value_ptr.*, 1) catch
            return error.GcUnderflow;
    }

    var attached: foundation.inline_rows.List(model.AnswerName, 8) = .empty;
    defer attached.deinit(scratch);
    try attached.ensureUnusedCapacity(scratch, positions.len);
    errdefer for (attached.items()) |name| {
        const row = self.inbound_answers.getPtr(name) orelse unreachable;
        const answer_payload = row.payload orelse unreachable;
        row.payload = null;
        const released = answers.releaseAnswerPayload(self.allocator, answer_payload);
        std.debug.assert(released.resolution == 0 and released.queued_calls == 0);
    };

    var detached_count: u32 = 0;
    var counts = decrements.iterator();
    while (counts.next()) |count| {
        const position = count.key_ptr.*;
        const name = model.AnswerName.fromWire(.from(position));
        const row = self.inbound_answers.getPtr(name) orelse return error.GcUnderflow;
        if (row.count == 0 or count.value_ptr.* > row.count) return error.GcUnderflow;
        if (row.count != count.value_ptr.*) continue;
        const has_resolver = self.resolverForInboundAnswer(name) != null;
        if (has_resolver and row.payload == null) {
            _ = try answers.ensureAnswerPayload(self.allocator, row);
            attached.appendAssumeCapacity(name);
        }
        if (row.payload) |answer_payload| {
            if (has_resolver or answer_payload.hasConsequences())
                detached_count = std.math.add(u32, detached_count, 1) catch
                    return error.QueueCapExceeded;
        }
    }
    try prepareDetachedCapacity(self, detached_count);
    counts = decrements.iterator();
    while (counts.next()) |count| {
        const name = model.AnswerName.fromWire(.from(count.key_ptr.*));
        const row = self.inbound_answers.getPtr(name) orelse unreachable;
        if (row.count != count.value_ptr.*) continue;
        if (self.resolverForInboundAnswer(name)) |resolver_import|
            row.payload.?.resolver_import = resolver_import;
    }
}

/// Commit the final decrement of one inbound answer after `prepareGc`.
/// Future pipelining dies now. Calls, projections, and notifications already
/// accepted for this incarnation move to the detached row-id store without
/// allocation. The wire name becomes immediately reusable without cancelling
/// work that crossed the receive transaction before the release.
pub fn commitFinalGc(self: *Session, name: model.AnswerName) void {
    const row = self.inbound_answers.getPtr(name) orelse unreachable;
    std.debug.assert(row.count == 1);
    row.count = 0;
    _ = self.v1_0_inbound_resolver_link.remove(name); // idempotent: an answer need not carry a resolver.
    if (row.payload) |answer_payload| {
        if (answer_payload.hasConsequences()) {
            const target: answers.AnswerTarget = .{ .name = name, .row_id = row.row_id };
            self.detached_inbound_answers.?.rows.putAssumeCapacity(
                target.row_id,
                .{ .target = target, .payload = answer_payload },
            );
            row.payload = null;
            self.inbound_answers.remove(name);
            return;
        }
    }
    lifecycle.releaseInboundCell(self, row);
    self.inbound_answers.remove(name);
}

pub fn beginNamed(self: *Session, name: model.AnswerName) !Settlement {
    const target = answerTargetNamed(self, name) orelse return error.InvalidReference;
    return begin(self, target);
}

/// Retain the stable payload before an application result enters any delayed
/// Node projection. Resolver/listener acceptance is then independent of the
/// partner releasing and reusing the answer name while entropy is pending.
pub fn begin(self: *Session, target: answers.AnswerTarget) !Settlement {
    var answer_payload = payload(self, target);
    if (answer_payload == null) {
        const row = self.inbound_answers.getPtr(target.name) orelse return error.InvalidReference;
        if (row.row_id != target.row_id) return error.InvalidReference;
        answer_payload = try answers.ensureAnswerPayload(self.allocator, row);
    }
    const owned = answer_payload.?;
    if (owned.resolution != null) return error.UnexpectedMessage;
    try answers.retainAnswerPayload(owned);
    if (owned.resolver_import == null) {
        // A detached target's former wire name may already identify a new
        // answer. Only the live row with this exact stamp may contribute its
        // resolver; final GC captured the old resolver before removing its status-allow: replacement state identity
        // link.
        if (self.inbound_answers.getPtr(target.name)) |row| {
            if (row.row_id == target.row_id)
                owned.resolver_import = self.resolverForInboundAnswer(target.name);
        }
    }
    return .{ .target = target, .payload = owned };
}

pub fn validateSettlement(
    self: *Session,
    target: answers.AnswerTarget,
    answer_payload: *answers.AnswerPayload,
    resolution_value: model.Resolution,
    inventory: session.Inventory,
) !void {
    const found = payload(self, target) orelse return error.InvalidReference;
    if (found != answer_payload) return error.InvalidReference;
    if (answer_payload.resolution != null) return error.UnexpectedMessage;
    try self.validateSentResolutionValue(resolution_value, inventory);
}

/// Give back one payload retain and the charges its final release returns.
/// This is the verb for a retain whose transaction never queued or drained a
/// carrier: a refused reservation, an abandoned fire target, a Node stage that
/// took the settlement another way. A carrier that left the wire releases
/// through `releaseCarrier`, which also retires the rows its notification
/// completed.
pub fn releasePayload(self: *Session, answer_payload: *answers.AnswerPayload) void {
    self.returnReleasedCharges(answers.releaseAnswerPayload(self.allocator, answer_payload));
}

/// Subtract the exact charges a final payload release gave back.
pub fn returnReleasedCharges(self: *Session, released: answers.ReleasedCharges) void {
    std.debug.assert(self.retained_sent_answer_bytes >= released.resolution);
    self.retained_sent_answer_bytes -= released.resolution;
    std.debug.assert(self.queued_call_bytes >= released.queued_calls);
    self.queued_call_bytes -= @intCast(released.queued_calls);
}

pub fn retainPayload(_: *Session, answer_payload: *answers.AnswerPayload) !void {
    try answers.retainAnswerPayload(answer_payload);
}

/// Subscribe the Host capability promise `promise` to an answer that is still
/// pending (ADR-0068): retain its payload, creating the box for a bare row,
/// and mark the payload so the Peer publishes one action when the answer
/// settles. The session's `max_lifted_answers` bounds the subscriptions, and
/// a payload already marked is refused as `UnexpectedMessage`, as is an answer
/// that already holds its resolution, whose subscriber would never be
/// notified: the caller follows the stored chain instead. The release is
/// `unsubscribeHostPromise`.
pub fn subscribeHostPromise(self: *Session, target: answers.AnswerTarget, promise: u64) !*answers.AnswerPayload {
    if (self.inbound_answers.host_promises >= self.limits.max_lifted_answers) return error.LiftedAnswerCapExceeded;
    const marked = try markHostPromise(self, target, promise);
    self.inbound_answers.host_promises += 1;
    return marked;
}

/// Move a subscription to the answer the first one's resolution named. The
/// next payload is prepared, retained, and marked before the first is
/// released, so a refusal leaves the subscription where it was, and the count
/// never moves because the move holds the one seat it held.
pub fn moveHostPromise(
    self: *Session,
    from: answers.AnswerTarget,
    from_payload: *answers.AnswerPayload,
    to: answers.AnswerTarget,
    promise: u64,
) !*answers.AnswerPayload {
    std.debug.assert(from_payload.host_promise == promise);
    const marked = try markHostPromise(self, to, promise);
    from_payload.host_promise = 0;
    from_payload.host_promise_notified = false;
    releaseCarrier(self, from, from_payload);
    return marked;
}

fn markHostPromise(self: *Session, target: answers.AnswerTarget, promise: u64) !*answers.AnswerPayload {
    var prepared = try answers.preparePendingPayloadTarget(self, target);
    errdefer prepared.abandon(self);
    if (prepared.payload.host_promise != 0) return error.UnexpectedMessage;
    try answers.retainAnswerPayload(prepared.payload);
    prepared.commit();
    prepared.payload.host_promise = promise;
    prepared.payload.host_promise_notified = false;
    return prepared.payload;
}

/// Leave a subscription made by `subscribeHostPromise`: clear the mark, return
/// the bound's seat, and release the retain, which also retires a detached row
/// the retain outlived. Whether the action was published is the caller's to
/// read first, because the Node seat it rode is the caller's.
pub fn unsubscribeHostPromise(self: *Session, target: answers.AnswerTarget, answer_payload: *answers.AnswerPayload) void {
    std.debug.assert(answer_payload.host_promise != 0);
    answer_payload.host_promise = 0;
    answer_payload.host_promise_notified = false;
    std.debug.assert(self.inbound_answers.host_promises > 0);
    self.inbound_answers.host_promises -= 1;
    releaseCarrier(self, target, answer_payload);
}

pub fn resolution(_: *Session, answer_payload: *answers.AnswerPayload) ?*const model.Resolution {
    if (answer_payload.resolution) |*stored| return &stored.value;
    return null;
}

pub fn storedResolution(_: *Session, answer_payload: *answers.AnswerPayload) ?*const answers.StoredResolution {
    if (answer_payload.resolution) |*stored| return stored;
    return null;
}

pub fn resolver(_: *Session, answer_payload: *answers.AnswerPayload) ?model.ImportPosition {
    return answer_payload.resolver_import;
}

pub fn takeListeners(self: *Session, answer_payload: *answers.AnswerPayload) ![]answers.ListenerEntry {
    return answer_payload.listeners.take(self.allocator);
}

pub fn restoreListeners(_: *Session, answer_payload: *answers.AnswerPayload, listeners: []answers.ListenerEntry) void {
    answer_payload.listeners.restoreOwned(listeners);
}

pub fn clearResolver(self: *Session, target: answers.AnswerTarget, answer_payload: *answers.AnswerPayload) void {
    answer_payload.resolver_import = null;
    if (self.inbound_answers.getPtr(target.name)) |row| {
        if (row.row_id == target.row_id)
            _ = self.v1_0_inbound_resolver_link.remove(target.name); // idempotent: the callback may already have cleared its link.
    }
}

fn noticeComplete(payload_in: *const answers.AnswerPayload) bool {
    return payload_in.resolution != null and
        payload_in.queue.items.len == 0 and
        payload_in.resolver_import == null and
        payload_in.listeners.len() == 0 and
        payload_in.projections.items.len == 0;
}

/// Remove a completed detached registry owner. Queued carriers retain the same
/// box, so this never invalidates a borrowed resolution. The final carrier
/// releases the exact stored charge.
pub fn retireDetached(self: *Session, target: answers.AnswerTarget, answer_payload: *answers.AnswerPayload) void {
    if (!noticeComplete(answer_payload)) return;
    // The caller is releasing one carrier retain. Keep the registry owner
    // while another carrier still borrows its tree, so local-capability
    // tracing can discover every not-yet-encoded payload. status-allow: pending state or quoted runtime label
    if (self.local_promises != null and answer_payload.refs > 2) return;
    const store = self.detached_inbound_answers orelse return;
    const row = store.rows.get(target.row_id) orelse return;
    if (row.payload != answer_payload or !targetEql(row.target, target)) return;
    const removed = store.rows.fetchRemove(target.row_id) orelse unreachable;
    releasePayload(self, removed.value.payload);
    if (store.rows.count() == 0) {
        store.rows.deinit(self.allocator);
        self.allocator.destroy(store);
        self.detached_inbound_answers = null;
    }
}

/// Resolver-only V1.0 answers have no wire name the partner can GC. Once their
/// one callback and local consequences are committed, remove the exact virtual
/// row. Queued listener carriers retain the stable payload independently.
pub fn retireVirtual(self: *Session, target: answers.AnswerTarget) void {
    if (target.name != .virtual) return;
    if (local_promise.isAnswer(self, target.name)) return;
    const row = self.inbound_answers.getPtr(target.name) orelse return;
    if (row.row_id != target.row_id) return;
    const answer_payload = row.payload orelse return;
    if (!noticeComplete(answer_payload)) return;
    if (self.local_promises != null and answer_payload.refs > 2) return;
    lifecycle.releaseInboundCell(self, row);
    self.inbound_answers.remove(target.name);
    _ = self.v1_0_inbound_resolver_link.remove(target.name); // idempotent: the callback may already have cleared its link.
}

/// Free the detached store at teardown, returning the charges its payloads'
/// final releases gave back for the session to subtract.
pub fn deinitDetached(self: *Session) answers.ReleasedCharges {
    const store = self.detached_inbound_answers orelse return .none;
    var released: answers.ReleasedCharges = .none;
    var rows = store.rows.valueIterator();
    while (rows.next()) |row| released.add(answers.releaseAnswerPayload(self.allocator, row.payload));
    store.rows.deinit(self.allocator);
    self.allocator.destroy(store);
    self.detached_inbound_answers = null;
    return released;
}

/// Retire a settled answer's carrier once its notification has left: the
/// virtual row, the detached row, the retain the carrier held, and the
/// local promise projections that release frees.
pub fn releaseCarrier(self: *Session, target: answers.AnswerTarget, answer_payload: *answers.AnswerPayload) void {
    retireVirtual(self, target);
    retireDetached(self, target, answer_payload);
    releasePayload(self, answer_payload);
    self.collectLocalPromiseProjections();
}
