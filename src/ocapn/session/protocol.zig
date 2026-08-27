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

/// Expose the state gate so the engine can run it before route-specific
/// preparation and commit.
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

/// The commit half of the engine's prepare/commit pairs records through
/// here, and nowhere else does. A prepare, in the same turn, created or
/// proved-held every position its message names, reserved its queue seat,
/// and left the session open — so admission is a turn-atomic assertion,
/// validation is the prepare's own construction, and `applySend` below is
/// infallible for the kinds a prepare builds: a listen's wire-delta retain
/// increments rows the prepare established (a found row's `getOrPut` takes
/// no allocation), an export release decrements counts the prepare's own
/// introductions retained, and an answer release retires a row the pending
/// carrier's mint proved live. Every arm then only forgets. `recordSend`'s
/// checks exist because its callers carry no such proof: its GC
/// re-verification may spill fold scratch to the heap, and a commit that has
/// spent its reservations has no honest answer to that arm.
pub fn recordPreparedSend(self: *Session, message: model.Message) void {
    std.debug.assert(self.state == .open);
    switch (message) {
        .listen, .gc_export, .gc_answer => apply.applySend(self, message) catch unreachable,
        // Only the kinds the prepare/commit pairs build; a new prepared kind
        // extends this switch with its own infallibility argument.
        else => unreachable,
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
    switch (message) {
        .deliver => |deliver| try prepareValidatedInboundDeliverOwned(self, deliver, &introduced),
        .resolve => try prepareIntroducedImports(self, &introduced),
        else => {},
    }
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
            switch (body) {
                .deliver => |deliver| try prepareValidatedInboundDeliverView(self, deliver, &introduced),
                .resolve => try prepareIntroducedImports(self, &introduced),
                else => {},
            }
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

/// Reserve every table row the validated deliver may add. The matching apply
/// then performs only bounded lookups, refcount increments, and
/// `putAssumeCapacity`; allocator refusal cannot split answer installation from
/// introduced-import retention after the engine has accepted the frame.
pub fn prepareValidatedInboundDeliverView(
    self: *Session,
    deliver: model.view.Deliver,
    introduced: *const validate.IntroducedImports,
) !void {
    try prepareValidatedInboundDeliver(self, deliver, introduced);
}

fn prepareValidatedInboundDeliverOwned(
    self: *Session,
    deliver: model.Deliver,
    introduced: *const validate.IntroducedImports,
) !void {
    try prepareValidatedInboundDeliver(self, deliver, introduced);
}

fn prepareValidatedInboundDeliver(
    self: *Session,
    deliver: anytype,
    introduced: *const validate.IntroducedImports,
) !void {
    if (deliver.answer) |answer|
        try self.prepareFreshInboundAnswerNamed(.fromWire(answer));
    try prepareIntroducedImports(self, introduced);
}

/// Reserve and overflow-check the import batch produced by one validation
/// walk. Every mention remains ordered in `introduced.mentions`; this preflight
/// only proves that replaying those increments at commit cannot fail.
pub fn prepareIntroducedImports(
    self: *Session,
    introduced: *const validate.IntroducedImports,
) !void {
    // A row can approach u64 exhaustion only after an infeasible number of
    // prior wire mentions. Keep exact duplicate counting off the ordinary path
    // and allocate it only when this frame's total mention count could possibly
    // overflow at least one held row.
    const mention_count = std.math.cast(u64, introduced.mentions.items.len) orelse
        return Error.GcUnderflow;
    var needs_exact_counts = false;
    for (introduced.mentions.items) |position| {
        const held = self.imports.count(position);
        if (mention_count > std.math.maxInt(u64) - held) {
            needs_exact_counts = true;
            break;
        }
    }
    if (needs_exact_counts) {
        var counts: std.AutoHashMapUnmanaged(model.ImportPosition, u64) = .empty;
        defer counts.deinit(introduced.allocator);
        for (introduced.mentions.items) |position| {
            const gop = try counts.getOrPut(introduced.allocator, position);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* = std.math.add(u64, gop.value_ptr.*, 1) catch
                return Error.GcUnderflow;
        }
        var it = counts.iterator();
        while (it.next()) |entry| {
            const held = self.imports.count(entry.key_ptr.*);
            if (entry.value_ptr.* > std.math.maxInt(u64) - held)
                return Error.GcUnderflow;
        }
    }
    try self.imports.ensureUnusedCapacity(self.allocator, introduced.seen.count());
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
    try prepareIntroducedImports(self, &introduced);
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
