//! Session validation: the "is this message even allowed?" half of the state
//! machine.
//!
//! These are methods of [`Session`] (aliased into the struct in `mod.zig`), so
//! `self.validateSend(msg)` resolves the same as before the split. They never
//! mutate authority; they only decide whether a message is well-formed and
//! permitted given the current tables and negotiated features, handing back a
//! typed [`Error`] (or the borrowed-view projection errors in [`RecvViewError`])
//! on a violation. The matching mutations live in `apply.zig`.
//!
//! There is exactly one set of `anytype` reference / argument walkers serving
//! both the owned `model.*` path and the borrowed `model.view.*` path, so the
//! two cannot drift.

const std = @import("std");
const model = @import("../model/mod.zig");
const session = @import("mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const BOOTSTRAP_EXPORT_ID = session.BOOTSTRAP_EXPORT_ID;

pub fn validateRecvView(self: *Session, body: model.view.Body) !void {
    // State admission is gated at the dispatch head (`admitInState`); this is
    // the kind-specific validation. `op:start-session` keeps its own
    // "negotiating-only" rule because the gate admits it in `open`/`draining`
    // too — a second handshake there is the kind-specific violation.
    switch (body) {
        .start_session => |ss| {
            if (self.state != .negotiating) return Error.UnexpectedMessage;
            if (self.handshake_remote_received) return Error.DuplicateStartSession;
            if (ss.captp_version != self.wire_profile.captp_version) {
                return Error.CaptpVersionMismatch;
            }
        },
        .deliver => |deliver| try self.validateInboundDeliverAny(deliver),
        .resolve => |resolve| try self.validateInboundResolve(resolve),
        .listen => |listen| {
            if (!self.features.pipelining) return Error.FeatureNotNegotiated;
            try self.validateTargetReference(listen.target);
            try self.validateArgumentReference(listen.listener);
        },
        else => {},
    }
}

/// Validate an inbound `op:resolve`. The answer must be one we allocated
/// (an outbound call awaiting its reply), and — symmetrically with a
/// deliver's args — the fulfill payload's references are validated and
/// depth-bounded: a `near` must name one of our exports, a `far` is a fresh
/// introduction, and the payload tree may not nest past `max_nesting_depth`.
/// Without this, a fulfill carrying a `near` to a non-existent export would
/// be accepted while the identical reference in a deliver arg is rejected.
pub fn validateInboundResolve(self: *Session, resolve: anytype) RecvViewError!void {
    if (!self.outbound_answers.contains(resolve.answer)) {
        return Error.InvalidReference;
    }
    switch (resolve.resolution) {
        .fulfill => |arg| try self.validateInboundArgument(arg, 0),
        .break_ => {},
    }
}

pub fn validateSend(self: *Session, message: model.Message) !void {
    // State admission is gated at the dispatch head (`admitInState`). The
    // handshake keeps its negotiating-only / no-duplicate rule here; every
    // other kind carries only its own send-side validation.
    switch (message) {
        .start_session => {
            if (self.state != .negotiating) return Error.UnexpectedMessage;
            if (self.handshake_local_sent) return Error.DuplicateStartSession;
        },
        .deliver => |deliver| try self.validateOutboundDeliver(deliver),
        .resolve => |resolve| {
            if (!self.inbound_answers.contains(resolve.answer)) {
                return Error.InvalidReference;
            }
        },
        .gc_export => |gc_export| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            try session.validateGcExport(gc_export);
            // Outbound `op:gc-exports` releases our refs to the partner's
            // exports — decrements the import table.
            try session.checkGcExportDecrement(self.allocator, &self.imports, gc_export);
        },
        .gc_answer => |gc_answer| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            // The deliverer that allocated an answer-pos sends
            // `op:gc-answers` once it no longer needs the result, so an
            // outbound gc-answers releases a question we asked and decrements
            // our outbound answers (CapTP spec § op:gc-answers; Goblins sends
            // `cmd-send-gc-answer` from its question will-handler).
            try session.checkGcAnswerDecrement(self.allocator, &self.outbound_answers, gc_answer.positions);
        },
        .listen => |listen| {
            if (!self.features.pipelining) return Error.FeatureNotNegotiated;
            try self.validateOutboundReference(listen.target);
            try self.validateOutboundReference(listen.listener);
        },
        .handoff => |handoff| {
            if (!self.features.handoff) return Error.FeatureNotNegotiated;
            try session.validateHandoffWellFormed(handoff);
        },
        // abort / get / index carry no send-side validation.
        else => {},
    }
}

pub fn validateRecv(self: *Session, message: model.Message) !void {
    // State admission is gated at the dispatch head (`admitInState`). Inbound
    // `op:start-session` keeps its negotiating-only / no-duplicate rule and
    // also checks the partner's CapTP version against this session's profile.
    switch (message) {
        .start_session => |ss| {
            if (self.state != .negotiating) return Error.UnexpectedMessage;
            if (self.handshake_remote_received) return Error.DuplicateStartSession;
            if (ss.captp_version != self.wire_profile.captp_version) {
                return Error.CaptpVersionMismatch;
            }
            return;
        },
        .abort => {},
        else => {},
    }
    switch (message) {
        .deliver => |deliver| try self.validateInboundDeliverAny(deliver),
        .resolve => |resolve| try self.validateInboundResolve(resolve),
        .gc_export => |gc_export| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            try session.validateGcExport(gc_export);
            // Inbound `op:gc-exports` is the partner releasing refs to our
            // exports — decrements the export table.
            try session.checkGcExportDecrement(self.allocator, &self.exports, gc_export);
        },
        .gc_answer => |gc_answer| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            // Inbound `op:gc-answers` is the partner GCing a question it
            // asked us to answer, so it releases the inbound answers we
            // created for it (Goblins removes from its `answers` table on
            // `op:gc-answers`).
            try session.checkGcAnswerDecrement(self.allocator, &self.inbound_answers, gc_answer.positions);
        },
        .listen => |listen| {
            if (!self.features.pipelining) return Error.FeatureNotNegotiated;
            try self.validateTargetReference(listen.target);
            try self.validateArgumentReference(listen.listener);
        },
        .handoff => |handoff| {
            if (!self.features.handoff) return Error.FeatureNotNegotiated;
            try session.validateHandoffWellFormed(handoff);
            switch (handoff) {
                .receive => |receive| try self.validateInboundWithdraw(receive),
                .give => {},
            }
        },
        .abort => {},
        else => {},
    }
}

pub fn validateOutboundDeliver(self: *Session, deliver: model.Deliver) !void {
    try self.validateOutboundReference(deliver.target);
    if (deliver.resolve_me_desc) |reference| {
        try self.validateOutboundReference(reference);
    }
    try self.validateArguments(deliver.args);
}

// ── Inbound reference / argument validation (single walker) ─────────────
//
// The session validates two inbound representations: an owned `model.*`
// message (the retain path, via [`validateRecv`]) and a borrowed
// `model.view.*` projection (the steady-state path, via [`validateRecvView`]).
// `model.view.Reference` reuses `model.NearRef` / `model.FarRef`, and both
// `Argument` unions share arm names, so one set of `anytype` walkers serves
// both. There is exactly one copy of each rule, so the owned and borrowed
// paths cannot drift — proven by the inbound `far`-target rejection test in
// `test/session/session_test.zig` running through `recordRecvView`.

pub fn validateInboundDeliverAny(self: *Session, deliver: anytype) RecvViewError!void {
    try self.validateTargetReference(deliver.target);
    if (deliver.resolve_me_desc) |reference| {
        try self.validateTargetReference(reference);
    }
    try self.validateInboundArguments(deliver.args, 0);
}

/// Validate a pipelined inbound deliver — one whose target is a still-pending
/// answer the engine queues rather than surfacing now. It gets the *same*
/// reference, argument, and depth validation a directly-delivered call gets,
/// so a malformed-reference or over-deep pipelined call is rejected exactly
/// like its direct twin instead of slipping past validation onto the queue.
/// Validation only: the answer install and any import introduction happen
/// when the call is later drained and redirected at its resolved target.
pub fn validatePipelinedDeliver(self: *Session, deliver: anytype) RecvViewError!void {
    try self.validateInboundDeliverAny(deliver);
}

/// A reference in *target position* — a deliver target, a `resolve_me_desc`,
/// or a `listen` target/listener. Post perspective-flip (ADR-0010) a decoded
/// `near` names one of our exports and a decoded `far` names an import we
/// already hold (the bootstrap import 0 is implicitly held). An unheld `far`
/// here is the partner naming a capability that does not exist for us and is
/// rejected — distinct from [`validateArgumentReference`], where a `far` is a
/// fresh introduction.
pub fn validateTargetReference(self: *Session, reference: anytype) Error!void {
    switch (reference) {
        .near => |near| if (!self.exports.contains(near.export_id)) return Error.InvalidReference,
        .far => |far| if (far.import_id != BOOTSTRAP_EXPORT_ID and
            !self.imports.contains(far.import_id))
            return Error.InvalidReference,
        .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

/// A reference in *argument position* (a deliver's args or a resolution's
/// fulfill payload). A `near` names one of our exports and must be held; a
/// `far` is the partner *introducing* an import to us (a valid new
/// `<desc:import-object>`), accepted here and installed in apply.
pub fn validateArgumentReference(self: *Session, reference: anytype) Error!void {
    switch (reference) {
        .near => |near| if (!self.exports.contains(near.export_id)) return Error.InvalidReference,
        .far, .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

pub fn validateInboundArguments(self: *Session, args: anytype, depth: usize) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        // Forward cursor: one linear pass over the borrowed list region, no
        // per-element `at(i)` re-scan from the start and no `len()` pre-walk.
        var it = args.iterator();
        while (try it.next()) |arg| try self.validateInboundArgument(arg, depth);
    } else {
        for (args) |arg| try self.validateInboundArgument(arg, depth);
    }
}

pub fn validateInboundArgument(self: *Session, arg: anytype, depth: usize) RecvViewError!void {
    switch (arg) {
        .reference => |reference| try self.validateArgumentReference(reference),
        .list, .set => |items| try self.validateInboundArguments(items, depth + 1),
        .tagged => |tagged| try self.validateInboundArguments(tagged.value, depth + 1),
        else => {},
    }
}

pub fn validateOutboundReference(self: *Session, reference: model.Reference) !void {
    switch (reference) {
        // The partner's bootstrap (import 0) is always reachable on an open
        // session (ADR-0006) — symmetric with our own bootstrap export, which
        // `transitionToOpen` installs — so a far ref to it needs no prior
        // import-table entry. This is the outbound bootstrap-fetch /
        // sturdyref-enliven send target; every other import must be held.
        .far => |far| if (far.import_id != BOOTSTRAP_EXPORT_ID and
            !self.imports.contains(far.import_id))
            return Error.InvalidReference,
        .near => |near| if (!self.exports.contains(near.export_id)) return Error.InvalidReference,
        .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

pub fn validateArguments(self: *Session, args: []const model.Argument) Error!void {
    for (args) |arg| {
        try self.validateArgument(arg);
    }
}

pub fn validateArgument(self: *Session, arg: model.Argument) Error!void {
    switch (arg) {
        .reference => |reference| try self.validateOutboundReference(reference),
        .list => |items| try self.validateArguments(items),
        .set => |items| try self.validateArguments(items),
        .tagged => |tagged| try self.validateArguments(tagged.value),
        else => {},
    }
}
