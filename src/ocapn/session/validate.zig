//! Session validation: the "is this message even allowed?" half of the state
//! machine.
//!
//! The public spine is the three dispatch validators (`validateSend`,
//! `validateRecv`, `validateRecvView`), reached through `Session.recordSend` /
//! `recordRecv` / `recordRecvView`, plus the two kind validators the engine
//! runs before its own pre-apply steps (`validatePipelinedDeliver`,
//! `validateInboundListen`). Everything else is module-local: the per-kind
//! rules and the reference / argument walkers are implementation detail of
//! this file, called directly (`validateReference(self, ref, .held_import)`),
//! not methods on `Session`. Validators never mutate authority; they only decide
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
const REDEEMED_TOKEN_BASE = session.REDEEMED_TOKEN_BASE;

pub fn validateRecvView(self: *Session, body: model.view.Body) !void {
    // State admission is gated at the dispatch head (`admitInState`); this is
    // the kind-specific validation. `op:start-session` keeps its own
    // "negotiating-only" rule because the gate admits it in `open` too, a
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
/// rule, and the listener rule, exactly the checks the `.listen` dispatch
/// arms run. Public because the engine's listener install
/// (`engine.pipeline.maybeInstallInboundListener`) runs ahead of
/// `recordRecvView` and must validate before it mutates; both dispatch arms
/// call this same body, so the engine pre-step and the recv path cannot drift.
pub fn validateInboundListen(self: *Session, listen: anytype) RecvViewError!void {
    if (!self.features.pipelining) return Error.FeatureNotNegotiated;
    try validateReference(self, listen.target, .held_import);
    try validateReference(self, listen.listener, .introduction);
}

/// Validate an inbound `op:resolve`. The answer must be one we allocated
/// (an outbound call awaiting its reply), and — symmetrically with a
/// deliver's args — the fulfill payload's references are validated and
/// depth-bounded: a `near` must name one of our exports, a `far` is a fresh
/// introduction, and the payload tree may not nest past `max_nesting_depth`.
/// Without this, a fulfill carrying a `near` to a non-existent export would
/// be accepted while the identical reference in a deliver arg is rejected.
///
/// Public because the engine's V1.0 resolver-callback translation
/// (`Session.recordResolverCallbackResolve`) validates a synthesized resolve
/// with this exact body — minus the wire-`op:resolve` refusal in
/// `validateRecvView` — so the synthesized and canonical resolve paths cannot
/// drift.
pub fn validateInboundResolve(self: *Session, resolve: anytype) RecvViewError!void {
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
            // The fulfill payload's `near` references are deliberately *not*
            // validated as held here: resolving an answer with a `.near` is how
            // the application exports that object for the first time, so
            // `retainSentExports` mints the export row (`ExportTable.retain`
            // inserts at count 1). This is the send-side asymmetry with
            // `validateInboundResolve`, where a partner-named `near` must already
            // be one of our exports. The depth is still bounded here, before
            // `retainSentExports` walks the same payload and enforces the cap
            // mid-mutation: without this a too-deep fulfill would mint the
            // shallow export at count 1 and then trip `NestingTooDeep`, leaving
            // a refcount inflated that never went on the wire and no partner
            // `op:gc-exports` will ever release — the all-or-nothing breach the
            // deliver path already closes.
            switch (resolve.resolution) {
                .fulfill => |arg| try validateArgument(self, arg, 0, .skip),
                .@"break" => {},
            }
        },
        .gc_export => |gc_export| {
            if (!self.features.wire_delta) return Error.FeatureNotNegotiated;
            try session.validateGcExport(gc_export);
            // Our import 0 is the partner's pinned bootstrap — always reachable
            // without a table row (`validateReference` with `.held_import`) and outside
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
            // `op:gc-answers` when it releases the question, so an outbound
            // gc-answers releases a question we asked and decrements
            // our outbound answers (CapTP spec § op:gc-answers; Goblins sends
            // `cmd-send-gc-answer` from its question will-handler).
            try session.checkGcAnswerDecrement(self.allocator, &self.outbound_answers, gc_answer.positions);
        },
        .listen => |listen| {
            if (!self.features.pipelining) return Error.FeatureNotNegotiated;
            try validateReference(self, listen.target, .held_import);
            try validateReference(self, listen.listener, .held_import);
        },
        .handoff => |handoff| {
            if (!self.features.handoff) return Error.FeatureNotNegotiated;
            try session.validateHandoffWellFormed(handoff);
        },
        // `op:get` / `op:index` / `op:untag` name a receiver like a deliver
        // target: it must be something we hold (ADR-0050).
        .get => |get| try validateReference(self, get.receiver, .held_import),
        .index => |index| try validateReference(self, index.receiver, .held_import),
        .untag => |untag| try validateReference(self, untag.receiver, .held_import),
        // `op:abort` carries no send-side validation. Listing the remaining
        // no-op kinds explicitly (rather than `else`) makes a new
        // `model.Message` kind fail to compile until its send-side validation
        // is classified here — the silent-drop that produced the wire-delta
        // bug cannot recur.
        .abort => {},
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
            // exports, decrements the export table. The duplicate-position
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
        .get => |get| try validateReference(self, get.receiver, .held_import),
        .index => |index| try validateReference(self, index.receiver, .held_import),
        .untag => |untag| try validateReference(self, untag.receiver, .held_import),
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
    try validateReference(self, deliver.target, .held_import);
    if (deliver.resolve_me_desc) |reference| {
        try validateReference(self, reference, .held_import);
    }
    try validateArguments(self, deliver.args, 0, .held_import);
}

// ── Inbound reference / argument validation (single walker) ─────────────
//
// The session validates two inbound representations: an owned `model.*`
// message (the retain path, via `validateRecv`) and a borrowed
// `model.view.*` projection (the steady-state path, via `validateRecvView`).
// `model.view.Reference` reuses `model.NearRef` / `model.FarRef`, and both
// `Argument` unions share arm names, so one set of `anytype` walkers serves
// both. There is exactly one copy of each rule, so the owned and borrowed
// paths cannot drift, proven by the inbound `far`-target rejection test in
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
    seen: std.AutoHashMapUnmanaged(model.ImportId, void) = .empty,

    fn deinit(self: *ProspectiveImports, allocator: std.mem.Allocator) void {
        self.seen.deinit(allocator);
    }

    fn noteFar(self: *ProspectiveImports, s: *Session, import_position: model.ImportId) RecvViewError!void {
        if (import_position.int() == BOOTSTRAP_POSITION) return;
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
        if (answer.int() >= VIRTUAL_INBOUND_ANSWER_BASE) return Error.InvalidReference;
    }
    try validateReference(self, deliver.target, .held_import);
    if (deliver.resolve_me_desc) |reference| {
        try validateReference(self, reference, .held_import);
    }
    var new_imports: ProspectiveImports = .{};
    defer new_imports.deinit(self.allocator);
    try validateInboundArguments(self, deliver.args, 0, &new_imports);
}

/// Validate a pipelined inbound deliver, one whose target is a still-pending
/// answer the engine queues rather than dispatching immediately. It gets the *same*
/// reference, argument, depth, and answer-pos validation a directly-delivered
/// call gets, so a malformed-reference or over-deep pipelined call is rejected
/// exactly like its direct twin instead of slipping past validation onto the
/// queue. Validation only: the answer install and any import introduction
/// happen when the call is later drained and redirected at its resolved target.
pub fn validatePipelinedDeliver(self: *Session, deliver: anytype) RecvViewError!void {
    try validateInboundDeliverAny(self, deliver);
}

/// How the one reference validator treats a `far`. Everything else about a
/// reference is position-independent — a `near` always names one of our exports
/// and must be held, `promise`/`broken` are always acceptable, and a `sturdy`
/// always requires the negotiated sturdyref feature — so the `far` arm is the
/// only axis a position varies on.
const FarPolicy = enum {
    /// The `far` names an import we must already hold: a deliver/listen target,
    /// a projection receiver, or any reference we put on the wire ourselves.
    /// The bootstrap import (0) is implicitly held (ADR-0006). An unheld `far`
    /// here names a capability that does not exist for this session.
    held_import,
    /// The `far` is a fresh introduction — the partner handing us a new
    /// `<desc:import-object>` in argument or fulfill-payload position — accepted
    /// here and installed in apply, except in the reserved redeemed-token range
    /// (see `REDEEMED_TOKEN_BASE`), which is refused so a partner cannot alias a
    /// node-minted handoff token.
    introduction,
};

/// The one reference-position validator. Post perspective-flip (ADR-0010) a
/// decoded `near` names one of our exports; only the `far` arm varies, by
/// `far_policy`. Dual-shape over the borrowed view reference and the owned
/// `model.Reference`, like the argument walkers that call it.
fn validateReference(self: *Session, reference: anytype, comptime far_policy: FarPolicy) Error!void {
    switch (reference) {
        .near => |near| if (!self.exports.contains(near.export_position)) return Error.InvalidReference,
        .far => |far| switch (far_policy) {
            .held_import => if (far.import_position.int() != BOOTSTRAP_POSITION and
                !self.imports.contains(far.import_position))
                return Error.InvalidReference,
            .introduction => if (far.import_position.int() >= REDEEMED_TOKEN_BASE) return Error.InvalidReference,
        },
        .promise, .broken => {},
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
            try validateReference(self, reference, .introduction);
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

/// How the send-side walker treats a leaf `reference`. The two send paths
/// share one depth-bounded walk and differ only here: a deliver's arguments
/// must each name a held import (`.held_import`), while a resolve's fulfill
/// payload does not — resolving with a `.near` is how the application first
/// exports that object (the export-on-resolve asymmetry), so its references
/// are only depth-bounded (`.skip`).
const SendRefCheck = enum { held_import, skip };

/// Validate a send-side argument tree: bound the nesting past
/// `max_nesting_depth`, and check each leaf reference per `ref_check`. The
/// depth bound is the twin of the apply-side `retainSentExportArgs` cap: on
/// both send paths a too-deep locally-built message would otherwise pass
/// validation and then trip `NestingTooDeep` mid-walk in `retainSentExports`,
/// over-retaining every shallow export mention before the refusal and
/// breaching apply's all-or-nothing contract. One walk, one depth threshold,
/// so the cap cannot drift between the deliver and resolve paths. `ref_check`
/// is comptime, so the reference branch folds away per call site.
fn validateArguments(self: *Session, args: []const model.Argument, depth: usize, comptime ref_check: SendRefCheck) Error!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| {
        try validateArgument(self, arg, depth, ref_check);
    }
}

fn validateArgument(self: *Session, arg: model.Argument, depth: usize, comptime ref_check: SendRefCheck) Error!void {
    switch (arg) {
        .reference => |reference| switch (ref_check) {
            .held_import => try validateReference(self, reference, .held_import),
            .skip => {},
        },
        .list => |items| try validateArguments(self, items, depth + 1, ref_check),
        .set => |items| try validateArguments(self, items, depth + 1, ref_check),
        .tagged => |tagged| try validateArguments(self, tagged.value, depth + 1, ref_check),
        .@"struct" => |entries| {
            if (depth + 1 > self.limits.max_nesting_depth) return Error.NestingTooDeep;
            for (entries) |entry| try validateArgument(self, entry.value, depth + 1, ref_check);
        },
        // Exhaustive on purpose, see `validateInboundArgument`.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}
