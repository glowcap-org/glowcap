//! Stored resolutions for inbound answers: the plan, prepare, and commit of
//! one resolution's exact retained-byte charge, and the reads of what an
//! answer resolved to. `Session` stays the authority boundary, and the rows
//! themselves live in `store.zig`.

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");
const store = @import("store.zig");

const Session = session.Session;

/// Allocation-free admission result for one stored resolution. It takes the
/// owned tree's measured charge, computes replacement delta and the durable-byte ceiling,
/// and resolves promise identity before any capacity reservation or authority
/// mutation. Preparation only materializes a missing lazy payload.
pub const ResolutionStorePlan = struct {
    entry: ?*store.AnswerCell,
    payload: ?*store.AnswerPayload,
    charge: usize,
    next_retained: usize,
    promise_target: ?store.AnswerTarget,
};

/// A plan whose payload exists, so the commit allocates nothing.
pub const PreparedResolutionStore = struct {
    plan: ResolutionStorePlan,
    payload: *store.AnswerPayload,
};

pub fn planResolutionStoreNamed(
    self: *Session,
    answer: model.AnswerName,
    resolution: model.Resolution,
    charge: usize,
) !ResolutionStorePlan {
    const entry = self.inbound_answers.getPtr(answer) orelse
        return error.InvalidReference;
    const prior_charge = if (entry.payload) |payload| payload.resolution_charge else 0;
    std.debug.assert(self.retained_sent_answer_bytes >= prior_charge);
    const without_prior = self.retained_sent_answer_bytes - prior_charge;
    const next_retained = std.math.add(usize, without_prior, charge) catch
        return error.RetainedAnswerCapExceeded;
    if (next_retained > @as(usize, self.limits.max_retained_sent_answer_bytes))
        return error.RetainedAnswerCapExceeded;
    return .{
        .entry = entry,
        .payload = entry.payload,
        .charge = charge,
        .next_retained = next_retained,
        .promise_target = try self.promiseTargetForResolution(resolution),
    };
}

pub fn prepareResolutionStore(self: *Session, plan: ResolutionStorePlan) !PreparedResolutionStore {
    const payload = plan.payload orelse try store.ensureAnswerPayload(self.allocator, plan.entry.?);
    return .{ .plan = plan, .payload = payload };
}

pub fn commitPreparedResolutionStore(
    self: *Session,
    prepared: PreparedResolutionStore,
    resolution: model.Resolution,
) void {
    if (prepared.payload.resolution) |prior|
        model.freeResolution(self.allocator, prior.value);
    self.retained_sent_answer_bytes = prepared.plan.next_retained;
    prepared.payload.resolution = .{
        .value = resolution,
        .promise_target = prepared.plan.promise_target,
    };
    prepared.payload.resolution_charge = prepared.plan.charge;
    if (prepared.plan.entry) |entry| if (entry.status() == .pending) entry.settle(resolution);
}

pub fn planResolutionStoreTarget(
    self: *Session,
    target: store.AnswerTarget,
    payload: *store.AnswerPayload,
    resolution: model.Resolution,
    charge: usize,
) !ResolutionStorePlan {
    const found = self.answerPayloadForTarget(target) orelse return error.InvalidReference;
    if (found != payload or payload.resolution != null) return error.UnexpectedMessage;
    std.debug.assert(self.retained_sent_answer_bytes >= payload.resolution_charge);
    const without_prior = self.retained_sent_answer_bytes - payload.resolution_charge;
    const next_retained = std.math.add(usize, without_prior, charge) catch
        return error.RetainedAnswerCapExceeded;
    if (next_retained > @as(usize, self.limits.max_retained_sent_answer_bytes))
        return error.RetainedAnswerCapExceeded;
    const promise_target = try self.promiseTargetForResolution(resolution);
    const live_entry = if (self.inbound_answers.getPtr(target.name)) |entry|
        if (entry.row_id == target.row_id) entry else null
    else
        null;
    return .{
        .entry = live_entry,
        .payload = payload,
        .charge = charge,
        .next_retained = next_retained,
        .promise_target = promise_target,
    };
}

/// Store one owned semantic resolution and move its exact charge into the
/// Session's retained-answer aggregate. Replacement computes its complete
/// accounting result before releasing the prior value.
pub fn storeResolutionNamed(self: *Session, answer: model.AnswerName, resolution: model.Resolution) !void {
    const charge = model.measureResolutionOwnedBytes(resolution) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    const plan = planResolutionStoreNamed(self, answer, resolution, charge) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    const prepared = prepareResolutionStore(self, plan) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    commitPreparedResolutionStore(self, prepared, resolution);
}

/// Store `resolution` on the wire-named inbound answer, taking ownership and
/// marking it resolved. A replacement preserves the prior value if measuring
/// or accounting for the new resolution fails. Every failure consumes the new
/// resolution.
pub fn storeResolution(self: *Session, answer: model.AnswerPosition, resolution: model.Resolution) !void {
    return storeResolutionNamed(self, .fromWire(answer), resolution);
}

pub fn retainedSentAnswerBytes(self: *const Session) usize {
    return self.retained_sent_answer_bytes;
}

/// Borrow the stored resolution for `answer`, if it has resolved. The borrow
/// remains valid until that answer is replaced or removed.
pub fn peekResolutionNamed(self: *Session, answer: model.AnswerName) ?*const model.Resolution {
    const stored = peekStoredResolutionNamed(self, answer) orelse return null;
    return &stored.value;
}

pub fn peekStoredResolutionNamed(self: *Session, answer: model.AnswerName) ?*const store.StoredResolution {
    const entry = self.inbound_answers.getPtr(answer) orelse return null;
    const payload = entry.payload orelse {
        std.debug.assert(entry.status() == .pending);
        return null;
    };
    std.debug.assert((payload.resolution != null) == (entry.status() != .pending));
    if (payload.resolution) |*resolution| return resolution;
    return null;
}

pub fn peekResolution(self: *Session, answer: model.AnswerPosition) ?*const model.Resolution {
    return peekResolutionNamed(self, .fromWire(answer));
}

/// Whether `answer` is a known inbound answer that has resolved.
pub fn answerResolvedNamed(self: *Session, answer: model.AnswerName) bool {
    const entry = self.inbound_answers.getPtr(answer) orelse return false;
    return entry.status() != .pending;
}

pub fn answerResolved(self: *Session, answer: model.AnswerPosition) bool {
    return answerResolvedNamed(self, .fromWire(answer));
}
