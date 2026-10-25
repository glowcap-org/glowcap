//! Queued-call, listener, and projection operations for inbound answers.
//!
//! A pending answer owns the consequences that arrived before its settlement:
//! calls to redirect, listeners to notify, and projections to resolve. This
//! module owns admission, bounded retention, and ownership transfer for those
//! three collections. The concrete row and lazy payload live in `store.zig`,
//! `Session` remains the authoritative aggregate.
//!
//! Every drain transfers the existing backing allocation to its caller. This
//! boundary adds no copy, second walk, or runtime dispatch.

const std = @import("std");

const model = @import("model");

const session = @import("../mod.zig");
const store = @import("store.zig");

const Error = session.Error;
const ListenerEntry = session.ListenerEntry;
const Projection = session.Projection;
const Session = session.Session;

/// One queue seat prepared without attaching a call to the answer. A cold row's
/// fresh empty payload is owned by the nested preparation until commit. A warm
/// row has only grown private queue capacity, which carries no semantic state.
pub const PreparedCallQueue = struct {
    payload: store.PreparedPendingPayload,
    /// The owned bytes the admitted call charges, and the session total once
    /// it commits. Admission checked both against `max_queued_call_bytes`.
    charge: usize,
    next_queued_bytes: u32,

    pub fn abandon(self: *PreparedCallQueue, owner: *Session) void {
        self.payload.abandon(owner);
    }

    pub fn commit(self: *PreparedCallQueue, owner: *Session, message: model.Message) void {
        self.commitNamed(owner, .{ .message = message, .charge = self.charge, .answer = switch (message) {
            .deliver => |deliver| if (deliver.answer) |answer| owner.answerTargetNamed(.fromWire(answer)) else null,
            else => null,
        } });
    }

    pub fn commitNamed(self: *PreparedCallQueue, owner: *Session, call: store.QueuedCall) void {
        std.debug.assert(call.charge == self.charge);
        std.debug.assert(owner.queued_call_bytes + self.charge == self.next_queued_bytes);
        self.payload.payload.queue.appendAssumeCapacity(call);
        owner.queued_call_bytes = self.next_queued_bytes;
        self.payload.commit();
    }
};

/// Mint the next outbound answer position for a question stamped now. The
/// carrying send installs the row, and `abandonOutboundAnswer` returns a
/// position the send never carried. A released position is minted before the
/// frontier moves.
pub fn allocateOutboundAnswer(self: *Session) std.mem.Allocator.Error!session.OutboundAnswerTarget {
    return self.outbound_answers.reserve(self.allocator, self.nextStoreStamp());
}

/// Queue an owned pipelined call on a wire-named pending answer.
pub fn enqueuePipelinedCall(
    self: *Session,
    answer_position: model.AnswerPosition,
    message: model.Message,
) !void {
    return enqueuePipelinedCallNamed(self, .fromWire(answer_position), message);
}

/// Queue an owned pipelined call. Every refusal consumes the message.
pub fn enqueuePipelinedCallNamed(
    self: *Session,
    answer_position: model.AnswerName,
    message: model.Message,
) !void {
    errdefer model.freeMessage(self.allocator, message);
    var prepared = try preparePipelinedCallNamed(self, answer_position, try model.measureMessageOwnedBytes(message));
    errdefer prepared.abandon(self);
    prepared.commit(self, message);
}

/// Prepare one bounded queue append without consuming a message or changing
/// answer semantics. This is the receive transaction's queue half. Commit is
/// allocation-free after the frame's answer/import/resolver authority moves.
/// `charge` is the owned bytes the call will hold
/// (`model.measureMessageOwnedBytes`), checked here against
/// `max_queued_call_bytes` so a refused call allocates nothing.
pub fn preparePipelinedCallNamed(
    self: *Session,
    answer_position: model.AnswerName,
    charge: usize,
) !PreparedCallQueue {
    const target = self.answerTargetNamed(answer_position) orelse return error.InvalidReference;
    return preparePipelinedCallTarget(self, target, charge);
}

pub fn preparePipelinedCallTarget(
    self: *Session,
    target: session.AnswerTarget,
    charge: usize,
) !PreparedCallQueue {
    const charge32 = std.math.cast(u32, charge) orelse return error.QueuedCallBytesExceeded;
    const next_queued_bytes = std.math.add(u32, self.queued_call_bytes, charge32) catch
        return error.QueuedCallBytesExceeded;
    if (next_queued_bytes > self.limits.max_queued_call_bytes)
        return error.QueuedCallBytesExceeded;
    var payload = try store.preparePendingPayloadTarget(self, target);
    errdefer payload.abandon(self);
    if (payload.payload.queue.items.len >= self.limits.queue_cap)
        return error.QueueCapExceeded;
    try payload.payload.queue.ensureUnusedCapacity(self.allocator, 1);
    return .{ .payload = payload, .charge = charge, .next_queued_bytes = next_queued_bytes };
}

/// Queue a call, charging its owned bytes against the session budget. A call
/// drained once and re-queued behind another pending answer keeps the charge
/// it was measured at; a fresh call (charge zero, which no message measures
/// to) is measured here, and the stored call carries the result.
pub fn enqueuePipelinedCallTarget(
    self: *Session,
    target: session.AnswerTarget,
    call: store.QueuedCall,
) !void {
    errdefer call.deinit(self.allocator);
    const charge = if (call.charge != 0) call.charge else try model.measureMessageOwnedBytes(call.message);
    var prepared = try preparePipelinedCallTarget(self, target, charge);
    errdefer prepared.abandon(self);
    var charged = call;
    charged.charge = charge;
    prepared.commitNamed(self, charged);
}

pub fn takePipelinedCalls(
    self: *Session,
    answer_position: model.AnswerPosition,
) ![]store.QueuedCall {
    return takePipelinedCallsNamed(self, .fromWire(answer_position));
}

/// Transfer the complete queued-call allocation to the caller.
pub fn takePipelinedCallsNamed(
    self: *Session,
    answer_position: model.AnswerName,
) ![]store.QueuedCall {
    const entry = self.inbound_answers.getPtr(answer_position) orelse return &.{};
    const payload = entry.payload orelse return &.{};
    return takePayloadCalls(self, payload);
}

/// Transfer calls already accepted for one exact answer incarnation. The
/// payload may be detached after `op:gc-answers`. Its row stamp, not the
/// reusable wire name, remains their owner until settlement.
pub fn takePayloadCalls(self: *Session, payload: *session.AnswerPayload) ![]store.QueuedCall {
    if (payload.queue.items.len == 0) return &.{};
    const calls = try payload.queue.toOwnedSlice(self.allocator);
    var released: usize = 0;
    for (calls) |call| released += call.charge;
    self.returnReleasedCharges(.{ .queued_calls = released });
    return calls;
}

pub fn takePipelinedListeners(
    self: *Session,
    answer_position: model.AnswerPosition,
) ![]ListenerEntry {
    return takePipelinedListenersNamed(self, .fromWire(answer_position));
}

/// Transfer the complete listener allocation to the caller.
pub fn takePipelinedListenersNamed(
    self: *Session,
    answer_position: model.AnswerName,
) ![]ListenerEntry {
    const entry = self.inbound_answers.getPtr(answer_position) orelse return &.{};
    const payload = entry.payload orelse return &.{};
    return payload.listeners.take(self.allocator);
}

pub fn installListener(
    self: *Session,
    answer_position: model.AnswerPosition,
    listener: ListenerEntry,
) !void {
    return installListenerNamed(self, .fromWire(answer_position), listener);
}

/// Retain one POD listener on a known answer, bounded before lazy allocation.
/// The entry owns one session-held retain on its listener import
/// (`Session.retainImportForSession`), spent by the fire or discard that
/// consumes it.
pub fn installListenerNamed(
    self: *Session,
    answer_position: model.AnswerName,
    listener: ListenerEntry,
) !void {
    std.debug.assert(self.listenerRetainHeld(listener.listener));
    const target = self.answerTargetNamed(answer_position) orelse return error.InvalidReference;
    var prepared = try prepareListenerBatchTarget(self, target, 1);
    errdefer prepared.abandon(self);
    prepared.commit(&.{listener});
}

/// Exact pending-answer listener reservation. The nested payload preparation
/// owns any fresh lazy payload until commit, so a wider refusal leaves no empty
/// allocation attached to the row.
pub const PreparedListenerBatch = struct {
    payload: store.PreparedPendingPayload,

    pub fn abandon(self: *PreparedListenerBatch, owner: *Session) void {
        self.payload.abandon(owner);
    }

    pub fn commit(self: *PreparedListenerBatch, listeners: []const ListenerEntry) void {
        for (listeners) |listener| self.payload.payload.listeners.appendAssumeCapacity(listener);
        self.payload.commit();
    }
};

pub fn prepareListenerBatchTarget(
    self: *Session,
    target: session.AnswerTarget,
    count: usize,
) !PreparedListenerBatch {
    var payload = try store.preparePendingPayloadTarget(self, target);
    errdefer payload.abandon(self);
    const total = std.math.add(usize, payload.payload.listeners.len(), count) catch
        return error.ListenerCapExceeded;
    if (total > self.limits.max_listeners_per_target)
        return error.ListenerCapExceeded;
    try payload.payload.listeners.ensureUnusedCapacity(self.allocator, count);
    return .{ .payload = payload };
}

pub fn installProjection(
    self: *Session,
    answer_position: model.AnswerPosition,
    projection: Projection,
) !void {
    return installProjectionNamed(self, .fromWire(answer_position), projection);
}

/// Retain one owned projection on a pending answer. Every refusal consumes its
/// owned field/tag bytes, and the bound is checked before lazy allocation.
pub fn installProjectionNamed(
    self: *Session,
    answer_position: model.AnswerName,
    projection: Projection,
) !void {
    const target = self.answerTargetNamed(answer_position) orelse {
        store.deinitProjection(self.allocator, projection);
        return error.InvalidReference;
    };
    return installProjectionTarget(self, target, projection);
}

pub fn installProjectionTarget(
    self: *Session,
    target: session.AnswerTarget,
    projection: Projection,
) !void {
    errdefer store.deinitProjection(self.allocator, projection);
    var payload = try store.preparePendingPayloadTarget(self, target);
    errdefer payload.abandon(self);
    if (payload.payload.projections.items.len >= self.limits.max_listeners_per_target)
        return error.ProjectionCapExceeded;
    try payload.payload.projections.append(self.allocator, projection);
    payload.commit();
}

/// Transfer projections already accepted for one exact answer incarnation,
/// including an incarnation whose public wire name has since been released.
pub fn takePayloadProjections(self: *Session, payload: *session.AnswerPayload) ![]Projection {
    if (payload.projections.items.len == 0) return &.{};
    return payload.projections.toOwnedSlice(self.allocator);
}
