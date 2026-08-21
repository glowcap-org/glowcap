//! Atomic protocol admission and validate-to-apply dispatch for one Session.
//!
//! `Session` owns the authoritative tables and scratch arenas. This module owns
//! the operation that changes them: admit the current state, validate without
//! mutation, then apply exactly once. The owned and borrowed receive paths meet
//! here so a codec representation cannot acquire different authority rules.
//!
//! Every function operates in place. This boundary adds no allocation, copy,
//! or second argument walk; the borrowed path keeps the introduced-import
//! record produced by validation and hands that same record to apply.

const std = @import("std");
const model = @import("model");

const session = @import("mod.zig");
const answer_notifications = @import("answers/notifications.zig");
const apply = @import("apply.zig");
const validate = @import("validate.zig");

const AnswerPayload = session.AnswerPayload;
const AnswerTarget = session.AnswerTarget;
const Error = session.Error;
const Session = session.Session;

/// Record one answer settlement whose payload has already been retained.
/// Consumes `resolution` on every outcome.
pub fn recordSentResolutionTarget(
    self: *Session,
    target: AnswerTarget,
    payload: *AnswerPayload,
    resolution: model.Resolution,
) !void {
    var apply_owns_resolution = false;
    errdefer if (!apply_owns_resolution) model.freeResolution(self.allocator, resolution);
    try admitOpen(self);
    try answer_notifications.validateSettlement(self, target, payload, resolution);
    apply_owns_resolution = true;
    try apply.applySentResolutionTarget(self, target, payload, resolution);
}

pub fn close(self: *Session) void {
    self.state = .closed;
}

/// Exhaustive session-state admission gate (ADR-0006), run at every dispatch
/// head. Kind-specific rules remain in the per-message validators.
fn admitInState(self: *const Session, message: anytype) Error!void {
    switch (self.state) {
        .closed => return Error.SessionClosed,
        .negotiating => switch (message) {
            .start_session, .abort => {},
            else => return Error.UnexpectedMessage,
        },
        .open => {},
    }
}

/// Admit a semantic operation that has no wire-message tag of its own.
fn admitOpen(self: *const Session) Error!void {
    switch (self.state) {
        .closed => return Error.SessionClosed,
        .negotiating => return Error.UnexpectedMessage,
        .open => {},
    }
}

/// Expose the state gate so the engine can run it before any pre-record
/// authority mutation such as resolver registration or pipeline retention.
pub fn admits(self: *const Session, body: model.view.Body) Error!void {
    try admitInState(self, body);
}

pub fn recordSend(self: *Session, message: model.Message) !void {
    // Admit and validate borrow `message`. A sent resolve is consumed by apply,
    // while every other kind remains owned by the outbound queue.
    var apply_owns_resolution = false;
    errdefer if (message == .resolve and !apply_owns_resolution)
        model.freeResolution(self.allocator, message.resolve.resolution);
    try admitInState(self, message);
    try validate.validateSend(self, message);
    apply_owns_resolution = true;
    switch (message) {
        .resolve => |resolve| try apply.applySentResolve(self, resolve),
        else => try apply.applySend(self, message),
    }
}

/// Record one semantic inbound-answer settlement whose identity may be a wire
/// position or a session-local virtual answer. Consumes `resolution` always.
pub fn recordSentResolutionNamed(
    self: *Session,
    answer: model.AnswerName,
    resolution: model.Resolution,
) !void {
    var apply_owns_resolution = false;
    errdefer if (!apply_owns_resolution) model.freeResolution(self.allocator, resolution);
    try admitOpen(self);
    try validate.validateSentResolutionNamed(self, answer, resolution);
    apply_owns_resolution = true;
    try apply.applySentResolutionNamed(self, answer, resolution);
}

pub fn recordRecv(self: *Session, message: model.Message) !void {
    try admitInState(self, message);
    defer _ = self.recv_scratch.reset(.{
        .retain_with_limit = Session.steady_recv_scratch_bytes,
    });
    var introduced: validate.IntroducedImports = .init(
        self.recv_scratch.allocator(),
        self.limits,
    );
    try validate.validateRecv(self, message, &introduced);
    try apply.applyRecv(self, message, &introduced);
}

/// Borrowed-validate / owned-on-retain inbound path. Common message kinds
/// validate and apply directly from the codec-neutral view. GC vectors use one
/// turn-local owned materialization only after their feature gate succeeds.
pub fn recordRecvView(self: *Session, body: model.view.Body) !void {
    try admitInState(self, body);
    defer _ = self.recv_scratch.reset(.{
        .retain_with_limit = Session.steady_recv_scratch_bytes,
    });
    var introduced: validate.IntroducedImports = .init(
        self.recv_scratch.allocator(),
        self.limits,
    );
    switch (body) {
        .deliver, .resolve, .listen, .start_session, .abort, .get, .index, .untag => {
            try validate.validateRecvView(self, body, &introduced);
            try apply.applyRecvView(self, body, &introduced);
        },
        .gc_export, .gc_answer => {
            try refuseUnnegotiatedKind(self, body);
            const owned = try body.toOwned(self.recv_scratch.allocator());
            try validate.validateRecv(self, owned, &introduced);
            try apply.applyRecv(self, owned, &introduced);
        },
    }
}

/// Refuse an unnegotiated kind before an attacker-selected owned copy.
fn refuseUnnegotiatedKind(self: *const Session, body: model.view.Body) Error!void {
    switch (body) {
        .gc_export, .gc_answer => if (!self.features.wire_delta)
            return Error.FeatureNotNegotiated,
        else => {},
    }
}

/// Validate a borrowed inbound deliver before engine-owned resolver or
/// pipeline mutation. The caller retains `introduced` for the matching apply.
pub fn validateInboundDeliverView(
    self: *Session,
    deliver: model.view.Deliver,
    introduced: *validate.IntroducedImports,
) !void {
    const body = model.view.Body{ .deliver = deliver };
    try admitInState(self, body);
    defer _ = self.recv_scratch.reset(.{
        .retain_with_limit = Session.steady_recv_scratch_bytes,
    });
    try validate.validateRecvView(self, body, introduced);
}

/// Apply a deliver already accepted by `validateInboundDeliverView`.
pub fn applyValidatedInboundDeliverView(
    self: *Session,
    deliver: model.view.Deliver,
    introduced: *const validate.IntroducedImports,
) !void {
    try apply.applyRecvView(self, .{ .deliver = deliver }, introduced);
}

/// Record the semantic resolve synthesized from a resolver callback deliver.
pub fn recordResolverCallbackResolve(
    self: *Session,
    resolve: model.view.Resolve,
) !void {
    defer _ = self.recv_scratch.reset(.{
        .retain_with_limit = Session.steady_recv_scratch_bytes,
    });
    var introduced: validate.IntroducedImports = .init(
        self.recv_scratch.allocator(),
        self.limits,
    );
    try validateResolverCallbackResolve(self, resolve, &introduced);
    try applyValidatedResolverCallbackResolve(self, resolve, &introduced);
}

pub fn validateResolverCallbackResolve(
    self: *Session,
    resolve: model.view.Resolve,
    introduced: *validate.IntroducedImports,
) !void {
    const body = model.view.Body{ .resolve = resolve };
    try admitInState(self, body);
    try validate.validateInboundResolve(self, resolve, introduced);
}

pub fn applyValidatedResolverCallbackResolve(
    self: *Session,
    resolve: model.view.Resolve,
    introduced: *const validate.IntroducedImports,
) !void {
    try apply.applyRecvView(self, .{ .resolve = resolve }, introduced);
}

/// Commit a listener fire whose target, payload, export capacity, and outbound
/// carrier were all prepared before settlement. No failure remains legal.
pub fn commitPreparedListenerFire(self: *Session, message: model.Message) void {
    std.debug.assert(message == .deliver and message.deliver.answer == null);
    apply.applySend(self, message) catch unreachable;
}
