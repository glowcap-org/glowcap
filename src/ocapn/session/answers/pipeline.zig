//! Queued-call, listener, and projection operations for inbound answers.
//!
//! A pending answer owns the consequences that arrived before its settlement:
//! calls to redirect, listeners to notify, and projections to resolve. This
//! module owns admission, bounded retention, and ownership transfer for those
//! three collections. The concrete row and lazy payload live in `store.zig`;
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
/// fresh empty payload is owned by the nested preparation until commit; a warm
/// row has only grown private queue capacity, which carries no semantic state.
pub const PreparedCallQueue = struct {
    payload: store.PreparedPendingPayload,

    pub fn abandon(self: *PreparedCallQueue, owner: *Session) void {
        self.payload.abandon(owner);
    }

    pub fn commit(self: *PreparedCallQueue, message: model.Message) void {
        self.payload.payload.queue.appendAssumeCapacity(message);
        self.payload.commit();
    }
};

const max_mintable_outbound_answer = std.math.maxInt(u64) - 1;

/// Reserve the next outbound answer position. Recording the carrying deliver
/// installs the row; this operation only advances the collision-free cursor.
pub fn allocateOutboundAnswer(self: *Session) Error!model.AnswerPosition {
    try ensureOutboundAnswerCapacity(self, 1);
    const id = model.AnswerPosition.from(self.next_outbound_answer);
    self.next_outbound_answer += 1;
    return id;
}

fn ensureOutboundAnswerCapacity(self: *const Session, count: usize) Error!void {
    std.debug.assert(count > 0);
    if (self.next_outbound_answer > max_mintable_outbound_answer)
        return Error.OutboundAnswerSpaceExhausted;
    const available = max_mintable_outbound_answer - self.next_outbound_answer + 1;
    if (count > available) return Error.OutboundAnswerSpaceExhausted;
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
    var prepared = try preparePipelinedCallNamed(self, answer_position);
    errdefer prepared.abandon(self);
    prepared.commit(message);
}

/// Prepare one bounded queue append without consuming a message or changing
/// answer semantics. This is the receive transaction's queue half; commit is
/// allocation-free after the frame's answer/import/resolver authority moves.
pub fn preparePipelinedCallNamed(
    self: *Session,
    answer_position: model.AnswerName,
) !PreparedCallQueue {
    const target = self.answerTargetNamed(answer_position) orelse return Error.InvalidReference;
    return preparePipelinedCallTarget(self, target);
}

pub fn preparePipelinedCallTarget(
    self: *Session,
    target: session.AnswerTarget,
) !PreparedCallQueue {
    var payload = try store.preparePendingPayloadTarget(self, target);
    errdefer payload.abandon(self);
    if (payload.payload.queue.items.len >= self.limits.queue_cap)
        return Error.QueueCapExceeded;
    try payload.payload.queue.ensureUnusedCapacity(self.allocator, 1);
    return .{ .payload = payload };
}

pub fn enqueuePipelinedCallTarget(
    self: *Session,
    target: session.AnswerTarget,
    message: model.Message,
) !void {
    errdefer model.freeMessage(self.allocator, message);
    var prepared = try preparePipelinedCallTarget(self, target);
    errdefer prepared.abandon(self);
    prepared.commit(message);
}

pub fn takePipelinedCalls(
    self: *Session,
    answer_position: model.AnswerPosition,
) ![]model.Message {
    return takePipelinedCallsNamed(self, .fromWire(answer_position));
}

/// Transfer the complete queued-call allocation to the caller.
pub fn takePipelinedCallsNamed(
    self: *Session,
    answer_position: model.AnswerName,
) ![]model.Message {
    const entry = self.inbound_answers.getPtr(answer_position) orelse return &.{};
    const payload = entry.payload orelse return &.{};
    return takePayloadCalls(self, payload);
}

/// Transfer calls already accepted for one exact answer incarnation. The
/// payload may be detached after `op:gc-answers`; its row stamp, not the
/// reusable wire name, remains their owner until settlement.
pub fn takePayloadCalls(self: *Session, payload: *session.AnswerPayload) ![]model.Message {
    if (payload.queue.items.len == 0) return &.{};
    return payload.queue.toOwnedSlice(self.allocator);
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
pub fn installListenerNamed(
    self: *Session,
    answer_position: model.AnswerName,
    listener: ListenerEntry,
) !void {
    const target = self.answerTargetNamed(answer_position) orelse return Error.InvalidReference;
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
        return Error.ListenerCapExceeded;
    if (total > self.limits.max_listeners_per_target)
        return Error.ListenerCapExceeded;
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
        return Error.InvalidReference;
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
        return Error.ProjectionCapExceeded;
    try payload.payload.projections.append(self.allocator, projection);
    payload.commit();
}

pub fn takeProjections(
    self: *Session,
    answer_position: model.AnswerPosition,
) ![]Projection {
    return takeProjectionsNamed(self, .fromWire(answer_position));
}

/// Transfer the complete projection allocation and every owned field/tag to
/// the caller.
pub fn takeProjectionsNamed(
    self: *Session,
    answer_position: model.AnswerName,
) ![]Projection {
    const entry = self.inbound_answers.getPtr(answer_position) orelse return &.{};
    const payload = entry.payload orelse return &.{};
    return takePayloadProjections(self, payload);
}

/// Transfer projections already accepted for one exact answer incarnation,
/// including an incarnation whose public wire name has since been released.
pub fn takePayloadProjections(self: *Session, payload: *session.AnswerPayload) ![]Projection {
    if (payload.projections.items.len == 0) return &.{};
    return payload.projections.toOwnedSlice(self.allocator);
}
