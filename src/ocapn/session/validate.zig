//! Session validation: the "is this message even allowed?" half of the state
//! machine.
//!
//! The public spine is the three dispatch validators (`validateSend`,
//! `validateRecv`, `validateRecvView`), reached through `Session.recordSend` /
//! `recordRecv` / `recordRecvView`, plus the two kind validators the engine
//! runs before its own pre-apply steps (`validatePipelinedDeliver`,
//! `validateInboundListen`). Everything else is module-local: the per-kind
//! rules and the reference / argument walkers are implementation detail of
//! this file, called directly (`validateTargetReference(self, ref)`), not
//! methods on `Session`. Validators never mutate authority; they only decide
//! whether a message is well-formed and permitted given the current tables and
//! negotiated features, handing back a typed `Error` (or the borrowed-view
//! projection errors in `RecvViewError`) on a violation. The matching
//! mutations live in `apply.zig`.
//!
//! There is exactly one set of `anytype` reference / argument walkers serving
//! both the owned `model.*` path and the borrowed `model.view.*` path, so the
//! two cannot drift.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;
const VIRTUAL_INBOUND_ANSWER_BASE = session.VIRTUAL_INBOUND_ANSWER_BASE;

pub fn validateRecvView(self: *Session, body: model.view.Body) !void {
    // State admission is gated at the dispatch head (`admitInState`); this is
    // the kind-specific validation. `op:start-session` keeps its own
    // "negotiating-only" rule because the gate admits it in `open` too — a
    // second handshake there is the kind-specific violation.
    switch (body) {
        .start_session => |ss| try validateStartSession(self, ss, .remote_received),
        .deliver => |deliver| try validateInboundDeliverAny(self, deliver),
        .resolve => |resolve| {
            if (self.needsV1_0Translation()) return Error.UnexpectedMessage;
            try validateInboundResolve(self, resolve);
        },
        .listen => |listen| try validateInboundListen(self, listen),
        else => {},
    }
}

/// The one `op:start-session` kind rule, shared by all three dispatch
/// validators: the session must still be negotiating, this half of the
/// handshake must not have been observed yet (`half` names which flag the
/// caller's direction owns), and the declared CapTP version must match the
/// session's negotiated profile.
fn validateStartSession(
    self: *Session,
    ss: anytype,
    half: enum { local_sent, remote_received },
) Error!void {
    if (self.state != .negotiating) return Error.UnexpectedMessage;
    const already_observed = switch (half) {
        .local_sent => self.handshake_local_sent,
        .remote_received => self.handshake_remote_received,
    };
    if (already_observed) return Error.DuplicateStartSession;
    if (ss.captp_version != self.wire_profile.captp_version) {
        return Error.CaptpVersionMismatch;
    }
}

/// Validate an inbound `op:listen`: the pipelining feature gate, the target
/// rule, and the listener rule — exactly the checks the `.listen` dispatch
/// arms run. Public because the engine's listener install
/// (`engine.pipeline.maybeInstallInboundListener`) runs ahead of
/// `recordRecvView` and must validate before it mutates; both dispatch arms
/// call this same body, so the engine pre-step and the recv path cannot drift.
pub fn validateInboundListen(self: *Session, listen: anytype) RecvViewError!void {
    if (!self.features.pipelining) return Error.FeatureNotNegotiated;
    try validateTargetReference(self, listen.target);
    try validateArgumentReference(self, listen.listener);
}

/// Validate an inbound `op:resolve`. The answer must be one we allocated
/// (an outbound call awaiting its reply), and — symmetrically with a
/// deliver's args — the fulfill payload's references are validated and
/// depth-bounded: a `near` must name one of our exports, a `far` is a fresh
/// introduction, and the payload tree may not nest past `max_nesting_depth`.
/// Without this, a fulfill carrying a `near` to a non-existent export would
/// be accepted while the identical reference in a deliver arg is rejected.
fn validateInboundResolve(self: *Session, resolve: anytype) RecvViewError!void {
    const entry = self.outbound_answers.getPtr(resolve.answer) orelse
        return Error.InvalidReference;
    // An answer resolves exactly once. A second `op:resolve` for an
    // already-settled answer is a partner protocol violation, not a fresh
    // settlement: reject it (a protocol_error abort) instead of re-mutating
    // status and re-introducing the fulfill's imports.
    if (entry.status != .pending) return Error.UnexpectedMessage;
    switch (resolve.resolution) {
        .fulfill => |arg| {
            var new_imports: ProspectiveImports = .{};
            defer new_imports.deinit(self.allocator);
            try validateInboundArgument(self, arg, 0, &new_imports);
        },
        .@"break" => {},
    }
}

pub fn validateSend(self: *Session, message: model.Message) !void {
    // State admission is gated at the dispatch head (`admitInState`). The
    // handshake keeps its negotiating-only / no-duplicate rule here; every
    // other kind carries only its own send-side validation.
    switch (message) {
        .start_session => |ss| try validateStartSession(self, ss, .local_sent),
        .deliver => |deliver| try validateOutboundDeliver(self, deliver),
        .resolve => |resolve| {
            // An answer resolves exactly once on the send side too, symmetric
            // with `validateInboundResolve`: a second resolve for a settled
            // inbound answer would put our own protocol violation on the wire.
            const entry = self.inbound_answers.getPtr(resolve.answer) orelse
                return Error.InvalidReference;
            if (entry.status != .pending) return Error.UnexpectedMessage;
        },
        .gc_export => |gc_export| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            try session.validateGcExport(gc_export);
            // Our import 0 is the partner's pinned bootstrap — always reachable
            // without a table row (`validateOutboundReference`) and outside
            // wire-delta accounting — so releasing it is releasing an id the
            // table never holds. Refuse loudly rather than put a bootstrap
            // release on the wire (a partner that does account it, the way
            // Goblins does, would tear down its bootstrap export on receipt).
            for (gc_export.positions) |pos| {
                if (pos == BOOTSTRAP_POSITION) return Error.GcUnderflow;
            }
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
            try validateOutboundReference(self, listen.target);
            try validateOutboundReference(self, listen.listener);
        },
        .handoff => |handoff| {
            if (!self.features.handoff) return Error.FeatureNotNegotiated;
            try session.validateHandoffWellFormed(handoff);
        },
        // `op:get` / `op:index` / `op:untag` name a receiver like a deliver
        // target: it must be something we hold (ADR-0050).
        .get => |get| try validateOutboundReference(self, get.receiver),
        .index => |index| try validateOutboundReference(self, index.receiver),
        .untag => |untag| try validateOutboundReference(self, untag.receiver),
        // abort carries no send-side validation.
        else => {},
    }
}

pub fn validateRecv(self: *Session, message: model.Message) !void {
    // State admission is gated at the dispatch head (`admitInState`). Inbound
    // `op:start-session` keeps its negotiating-only / no-duplicate rule and
    // also checks the partner's CapTP version against this session's profile.
    switch (message) {
        .start_session => |ss| try validateStartSession(self, ss, .remote_received),
        .deliver => |deliver| try validateInboundDeliverAny(self, deliver),
        // No V1.0 wire-resolve refusal here: this path also validates the
        // engine-synthesized semantic `Resolve` from a resolver callback;
        // the wire refusal lives in `validateRecvView`.
        .resolve => |resolve| try validateInboundResolve(self, resolve),
        .gc_export => |gc_export| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            try session.validateGcExport(gc_export);
            // Inbound `op:gc-exports` is the partner releasing refs to our
            // exports — decrements the export table. The duplicate-position
            // scratch map is turn-scratch, so it bumps the recv arena and dies
            // with `recordRecvView`'s reset.
            try session.checkGcExportDecrement(self.recv_scratch.allocator(), &self.exports, gc_export);
        },
        .gc_answer => |gc_answer| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            // Inbound `op:gc-answers` is the partner GCing a question it
            // asked us to answer, so it releases the inbound answers we
            // created for it (Goblins removes from its `answers` table on
            // `op:gc-answers`). Scratch lives in the recv arena, as above.
            try session.checkGcAnswerDecrement(self.recv_scratch.allocator(), &self.inbound_answers, gc_answer.positions);
        },
        .listen => |listen| try validateInboundListen(self, listen),
        // `op:get` / `op:index` / `op:untag` name a receiver in target position,
        // exactly like a deliver target: the partner must already hold it.
        // Without this an inbound projection op with an unheld export/import id
        // would surface to the application unvalidated, an authority gap versus
        // deliver and listen.
        .get => |get| try validateTargetReference(self, get.receiver),
        .index => |index| try validateTargetReference(self, index.receiver),
        .untag => |untag| try validateTargetReference(self, untag.receiver),
        .handoff => |handoff| {
            if (!self.features.handoff) return Error.FeatureNotNegotiated;
            // Well-formedness only. Withdrawal authority (the vat-scoped
            // `engine.bootstrap.GiftRegistry`) moves solely through a verified
            // caller (`engine.bootstrap.resolveForWithdraw`, or a host that
            // verifies both handoff certificates before applying the withdraw
            // against the registry), never from this unauthenticated generic
            // inbound path. See the `.handoff` arm in `apply.zig`.
            try session.validateHandoffWellFormed(handoff);
        },
        // `op:abort` is always admitted and carries no kind-specific rule.
        else => {},
    }
}

fn validateOutboundDeliver(self: *Session, deliver: model.Deliver) !void {
    try validateOutboundReference(self, deliver.target);
    if (deliver.resolve_me_desc) |reference| {
        try validateOutboundReference(self, reference);
    }
    try validateArguments(self, deliver.args);
}

// ── Inbound reference / argument validation (single walker) ─────────────
//
// The session validates two inbound representations: an owned `model.*`
// message (the retain path, via `validateRecv`) and a borrowed
// `model.view.*` projection (the steady-state path, via `validateRecvView`).
// `model.view.Reference` reuses `model.NearRef` / `model.FarRef`, and both
// `Argument` unions share arm names, so one set of `anytype` walkers serves
// both. There is exactly one copy of each rule, so the owned and borrowed
// paths cannot drift — proven by the inbound `far`-target rejection test in
// `test/session/session_test.zig` running through `recordRecvView`.

/// Scratch tally of the distinct imports one inbound message would newly
/// install. The import cap must hold at *validate* time: apply commits the
/// answer row before it walks the args, so an `ImportCapExceeded` first
/// discovered in apply would break the all-or-nothing contract in `apply.zig`.
/// The walk counts prospective installs against `SessionLimits.max_imports`
/// with the same rules `registerImport` applies (bootstrap excluded,
/// already-held ids are refcount refreshes, one new id counts once however
/// often the message repeats it). Lazy: a message that introduces no new
/// import never allocates.
const ProspectiveImports = struct {
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn deinit(self: *ProspectiveImports, allocator: std.mem.Allocator) void {
        self.seen.deinit(allocator);
    }

    fn noteFar(self: *ProspectiveImports, s: *Session, import_position: u64) RecvViewError!void {
        if (import_position == BOOTSTRAP_POSITION) return;
        if (s.imports.contains(import_position)) return;
        const gop = try self.seen.getOrPut(s.allocator, import_position);
        if (gop.found_existing) return;
        if (s.imports.len() + self.seen.count() > s.limits.max_imports) {
            return Error.ImportCapExceeded;
        }
    }
};

fn validateInboundDeliverAny(self: *Session, deliver: anytype) RecvViewError!void {
    if (deliver.answer) |answer| {
        // The answer position is partner-named, so it is attacker-controlled.
        // The range at and above `VIRTUAL_INBOUND_ANSWER_BASE` is reserved for
        // session-allocated virtual answers; a partner claim there could
        // collide with a virtual allocation, so it is refused loudly.
        if (answer >= VIRTUAL_INBOUND_ANSWER_BASE) return Error.InvalidReference;
    }
    try validateTargetReference(self, deliver.target);
    if (deliver.resolve_me_desc) |reference| {
        try validateTargetReference(self, reference);
    }
    var new_imports: ProspectiveImports = .{};
    defer new_imports.deinit(self.allocator);
    try validateInboundArguments(self, deliver.args, 0, &new_imports);
}

/// Validate a pipelined inbound deliver — one whose target is a still-pending
/// answer the engine queues rather than surfacing now. It gets the *same*
/// reference, argument, depth, and answer-pos validation a directly-delivered
/// call gets, so a malformed-reference or over-deep pipelined call is rejected
/// exactly like its direct twin instead of slipping past validation onto the
/// queue. Validation only: the answer install and any import introduction
/// happen when the call is later drained and redirected at its resolved target.
pub fn validatePipelinedDeliver(self: *Session, deliver: anytype) RecvViewError!void {
    try validateInboundDeliverAny(self, deliver);
}

/// A reference in *target position* — a deliver target, a `resolve_me_desc`,
/// or a `listen` target/listener. Post perspective-flip (ADR-0010) a decoded
/// `near` names one of our exports and a decoded `far` names an import we
/// already hold (the bootstrap import 0 is implicitly held). An unheld `far`
/// here is the partner naming a capability that does not exist for us and is
/// rejected — distinct from `validateArgumentReference`, where a `far` is a
/// fresh introduction.
fn validateTargetReference(self: *Session, reference: anytype) Error!void {
    switch (reference) {
        .near => |near| if (!self.exports.contains(near.export_position)) return Error.InvalidReference,
        .far => |far| if (far.import_position != BOOTSTRAP_POSITION and
            !self.imports.contains(far.import_position))
            return Error.InvalidReference,
        .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

/// A reference in *argument position* (a deliver's args or a resolution's
/// fulfill payload). A `near` names one of our exports and must be held; a
/// `far` is the partner *introducing* an import to us (a valid new
/// `<desc:import-object>`), accepted here and installed in apply.
fn validateArgumentReference(self: *Session, reference: anytype) Error!void {
    switch (reference) {
        .near => |near| if (!self.exports.contains(near.export_position)) return Error.InvalidReference,
        .far, .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

fn validateInboundArguments(
    self: *Session,
    args: anytype,
    depth: usize,
    new_imports: *ProspectiveImports,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        // Forward cursor: one linear pass over the borrowed list region, no
        // per-element `at(i)` re-scan from the start and no `len()` pre-walk.
        var it = args.iterator();
        while (try it.next()) |arg| try validateInboundArgument(self, arg, depth, new_imports);
    } else {
        for (args) |arg| try validateInboundArgument(self, arg, depth, new_imports);
    }
}

fn validateInboundArgument(
    self: *Session,
    arg: anytype,
    depth: usize,
    new_imports: *ProspectiveImports,
) RecvViewError!void {
    switch (arg) {
        .reference => |reference| {
            try validateArgumentReference(self, reference);
            if (reference == .far) try new_imports.noteFar(self, reference.far.import_position);
        },
        .list, .set => |items| try validateInboundArguments(self, items, depth + 1, new_imports),
        .tagged => |tagged| try validateInboundArguments(self, tagged.value, depth + 1, new_imports),
        .@"struct" => |entries| try validateInboundStructEntries(self, entries, depth + 1, new_imports),
        // Exhaustive on purpose: a new Argument arm must decide here whether it
        // can carry a reference. The struct arm above was once missed behind an
        // `else`, which let a struct-wrapped reference dodge this walk entirely.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

/// Struct entries carry full argument values, so a reference can arrive inside
/// one; walk every entry's value like a list element. Dual-shape like its
/// callers: the borrowed `model.view.StructEntries` walks its lazy cursor,
/// the owned slice walks directly.
fn validateInboundStructEntries(
    self: *Session,
    entries: anytype,
    depth: usize,
    new_imports: *ProspectiveImports,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(entries) == model.view.StructEntries) {
        var it = entries.iterator();
        while (try it.next()) |entry| try validateInboundArgument(self, entry.value, depth, new_imports);
    } else {
        for (entries) |entry| try validateInboundArgument(self, entry.value, depth, new_imports);
    }
}

fn validateOutboundReference(self: *Session, reference: model.Reference) !void {
    switch (reference) {
        // The partner's bootstrap (import 0) is always reachable on an open
        // session (ADR-0006) — symmetric with our own bootstrap export, which
        // `transitionToOpen` installs — so a far ref to it needs no prior
        // import-table entry. This is the outbound bootstrap-fetch /
        // sturdyref-enliven send target; every other import must be held.
        .far => |far| if (far.import_position != BOOTSTRAP_POSITION and
            !self.imports.contains(far.import_position))
            return Error.InvalidReference,
        .near => |near| if (!self.exports.contains(near.export_position)) return Error.InvalidReference,
        .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

fn validateArguments(self: *Session, args: []const model.Argument) Error!void {
    for (args) |arg| {
        try validateArgument(self, arg);
    }
}

fn validateArgument(self: *Session, arg: model.Argument) Error!void {
    switch (arg) {
        .reference => |reference| try validateOutboundReference(self, reference),
        .list => |items| try validateArguments(self, items),
        .set => |items| try validateArguments(self, items),
        .tagged => |tagged| try validateArguments(self, tagged.value),
        .@"struct" => |entries| for (entries) |entry| try validateArgument(self, entry.value),
        // Exhaustive on purpose — see `validateInboundArgument`.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}
