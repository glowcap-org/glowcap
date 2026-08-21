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

const max_mintable_outbound_answer = std.math.maxInt(u64) - 1;

/// Reserve the next outbound answer position. Recording the carrying deliver
/// installs the row; this operation only advances the collision-free cursor.
pub fn allocateOutboundAnswer(self: *Session) Error!model.AnswerPosition {
    try ensureOutboundAnswerCapacity(self, 1);
    const id = model.AnswerPosition.from(self.next_outbound_answer);
    self.next_outbound_answer += 1;
    return id;
}

/// Reserve a contiguous span of outbound answers before a caller moves owned
/// pipeline payloads into messages that depend on those positions.
pub fn reserveOutboundAnswers(self: *Session, count: usize) Error!model.AnswerPosition {
    std.debug.assert(count > 0);
    try ensureOutboundAnswerCapacity(self, count);
    const first = model.AnswerPosition.from(self.next_outbound_answer);
    self.next_outbound_answer += @intCast(count);
    return first;
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
    const entry = self.inbound_answers.getPtr(answer_position) orelse
        return Error.InvalidReference;
    if (entry.status() != .pending) return Error.InvalidReference;
    const queued = if (entry.payload) |payload| payload.queue.items.len else 0;
    if (queued >= self.limits.queue_cap) return Error.QueueCapExceeded;
    const payload = try store.ensureAnswerPayload(self.allocator, entry);
    try payload.queue.append(self.allocator, message);
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

/// Move one owned call onto another pending answer. A direct cycle is refused;
/// longer cycles terminate because a settled answer cannot accept a requeue.
pub fn requeuePipelinedCall(
    self: *Session,
    target: model.AnswerPosition,
    seen: []const model.AnswerPosition,
    call: model.Message,
) !void {
    for (seen) |id| {
        if (id == target) {
            model.freeMessage(self.allocator, call);
            return Error.ResolutionCycle;
        }
    }
    return enqueuePipelinedCall(self, target, call);
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
    const entry = self.inbound_answers.getPtr(answer_position) orelse
        return Error.InvalidReference;
    const installed = if (entry.payload) |payload| payload.listeners.len() else 0;
    if (installed >= self.limits.max_listeners_per_target)
        return Error.ListenerCapExceeded;
    const payload = try store.ensureAnswerPayload(self.allocator, entry);
    try payload.listeners.append(self.allocator, listener);
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
    errdefer store.deinitProjection(self.allocator, projection);
    const entry = self.inbound_answers.getPtr(answer_position) orelse
        return Error.InvalidReference;
    const resolution_stored = if (entry.payload) |payload|
        payload.resolution != null
    else
        false;
    if (resolution_stored) return Error.InvalidReference;
    const installed = if (entry.payload) |payload| payload.projections.items.len else 0;
    if (installed >= self.limits.max_listeners_per_target)
        return Error.ProjectionCapExceeded;
    const payload = try store.ensureAnswerPayload(self.allocator, entry);
    try payload.projections.append(self.allocator, projection);
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
    if (payload.projections.items.len == 0) return &.{};
    return payload.projections.toOwnedSlice(self.allocator);
}
