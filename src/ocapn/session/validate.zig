//! Session validation: the "is this message even allowed?" half of the state
//! machine.
//!
//! The public spine is the three dispatch validators (`validateSend`,
//! `validateRecv`, `validateRecvView`), reached through `Session.recordSend` /
//! `recordRecv` / `recordRecvView`, plus the kind validators the engine runs
//! before its own pre-apply steps (`validateInboundDeliverView` and
//! `validateInboundListen`). Everything else is module-local: the per-kind
//! rules and the reference / argument walkers are implementation detail of
//! this file, called directly (`validateReference(self, ref, .received,
//! .held_import)`), not methods on `Session`. Validators never mutate
//! authority; they only decide
//! whether a message is well-formed and permitted given the current tables and
//! negotiated features, handing back a typed `Error` (or the borrowed-view
//! projection errors in `RecvViewError`) on a violation. The matching
//! mutations live in `apply.zig`.
//!
//! There is exactly one set of `anytype` reference / argument walkers serving
//! both the owned `model.*` path and the borrowed `model.view.*` path, so the
//! two cannot drift. That single walk also produces the `IntroducedImports`
//! record apply consumes, so one inbound message's argument bytes are
//! traversed exactly once between validation and apply.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const SessionLimits = session.SessionLimits;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

pub fn validateRecvView(self: *Session, body: model.view.Body, introduced: *IntroducedImports) !void {
    // State admission is gated at the dispatch head (`admitInState`); this is
    // the kind-specific validation. `op:start-session` keeps its own
    // "negotiating-only" rule because the gate admits it in `open` too, a
    // second handshake there is the kind-specific violation.
    switch (body) {
        .start_session => |ss| try validateStartSession(self, ss, .remote_received),
        .deliver => |deliver| try validateInboundDeliverAny(self, deliver, introduced),
        .resolve => |resolve| {
            if (self.needsV1_0Translation()) return Error.UnexpectedMessage;
            try validateInboundResolve(self, resolve, introduced);
        },
        .listen => |listen| try validateInboundListen(self, listen),
        .get => |get| try validateProjectionOp(self, get.receiver, get.answer),
        .index => |index| try validateProjectionOp(self, index.receiver, index.answer),
        .untag => |untag| {
            if (self.captp_version == .v1_0) return Error.UnexpectedMessage;
            try validateProjectionOp(self, untag.receiver, untag.answer);
        },
        else => {},
    }
}

/// The one inbound `op:get` / `op:index` / `op:untag` rule, shared by both
/// recv representations (`receiver` is the owned or borrowed reference): the
/// receiver names a target in exactly a deliver's position, so the partner
/// must already hold it, and the answer position must be fresh. Without this
/// an inbound projection op with an unheld position would surface to the
/// application unvalidated, an authority gap versus deliver and listen.
fn validateProjectionOp(self: *Session, receiver: anytype, answer: model.AnswerPosition) Error!void {
    try validateReference(self, receiver, .received, .held_import);
    try checkInboundAnswerPosition(self, answer);
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
    // A hello names the baseline version, not the sender's preference: a peer
    // that stated a preference here would be refused by every partner that did
    // not already share it, which is the opposite of negotiating. The
    // preference travels as a hint and governs the session once both hellos
    // are in. Compared against the baseline rather than the session's own
    // version because by this point the session may already have settled on
    // something else.
    if (ss.captp_version != model.Preference.baseline.captp_version) {
        return Error.CaptpVersionMismatch;
    }
    try validateStartSessionHints(ss);
}

fn validateStartSessionHints(ss: anytype) Error!void {
    const hints = ss.acceptable_location.hints;
    try validateHintNamesUnique(hints);
    if (try startSessionHintValue(hints, model.transport.hint_captp_version)) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return Error.MalformedMessage,
        };
        if (model.CaptpVersion.fromWireString(text) == null) return Error.MalformedMessage;
    }
    if (try startSessionHintValue(hints, model.transport.hint_codec)) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return Error.MalformedMessage,
        };
        _ = std.fmt.parseInt(u16, text, 10) catch return Error.MalformedMessage;
    }
    if (try startSessionHintValue(hints, model.transport.hint_features)) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return Error.MalformedMessage,
        };
        if (model.FeatureSet.fromWireString(text) == null) return Error.MalformedMessage;
    }
}

fn validateHintNamesUnique(hints: anytype) Error!void {
    if (comptime @hasDecl(@TypeOf(hints), "validateUniqueNames")) {
        hints.validateUniqueNames() catch return Error.MalformedMessage;
        return;
    }
    for (hints.entries, 0..) |entry, i| {
        for (hints.entries[0..i]) |seen| {
            if (std.mem.eql(u8, seen.name, entry.name)) return Error.MalformedMessage;
        }
    }
}

fn startSessionHintValue(hints: anytype, name: []const u8) Error!?model.HintValue {
    if (comptime @hasDecl(@TypeOf(hints), "findNamed")) {
        return hints.findNamed(name) catch return Error.MalformedMessage;
    }
    for (hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

/// Validate an inbound `op:listen`: the pipelining feature gate, the target
/// rule, and the listener rule, exactly the checks the `.listen` dispatch
/// arms run. Public because the engine's listener install
/// (`engine.pipeline.maybeInstallInboundListener`) runs ahead of
/// `recordRecvView` and must validate before it mutates; both dispatch arms
/// call this same body, so the engine pre-step and the recv path cannot drift.
pub fn validateInboundListen(self: *Session, listen: anytype) RecvViewError!void {
    if (!self.features.pipelining) return Error.FeatureNotNegotiated;
    try validateDeliverOrListenTarget(self, listen.target, .received);
    try validateListenListener(self, listen.listener, .received);
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
pub fn validateInboundResolve(self: *Session, resolve: anytype, introduced: *IntroducedImports) RecvViewError!void {
    const entry = self.outbound_answers.getPtr(resolve.answer) orelse
        return Error.InvalidReference;
    // An answer resolves exactly once. A second `op:resolve` for an
    // already-settled answer is a partner protocol violation, not a fresh
    // settlement: reject it (a protocol_error abort) instead of re-mutating
    // status and re-introducing the fulfill's imports.
    if (entry.status() != .pending) return Error.UnexpectedMessage;
    switch (resolve.resolution) {
        .fulfill => |arg| try validateInboundArgument(self, arg, 0, introduced),
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
            if (entry.status() != .pending) return Error.UnexpectedMessage;
            // The fulfill payload's `near` references are deliberately *not*
            // validated as held here, and only its `near` references: resolving
            // an answer with a `.near` is how the application exports that
            // object for the first time, so `retainSentExports` mints the
            // export row `registerExport`-shaped (local baseline plus the wire
            // mention) and advances the export allocator past it. Every other
            // arm keeps the deliver path's rule; see `SendRefCheck` for why the
            // `far` arm in particular cannot join the exemption. This is the
            // send-side asymmetry with
            // `validateInboundResolve`, where a partner-named `near` must
            // carry a wire-count grant. The depth is still bounded here, before
            // `retainSentExports` walks the same payload and enforces the cap
            // mid-mutation: without this a too-deep fulfill would mint the
            // shallow export at count 1 and then trip `NestingTooDeep`, leaving
            // a refcount inflated that never went on the wire and no partner
            // `op:gc-exports` will ever release — the all-or-nothing breach the
            // deliver path already closes.
            switch (resolve.resolution) {
                .fulfill => |arg| try validateArgument(self, arg, 0, .near_may_be_first_export),
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
            // The deliverer that allocated an answer position sends
            // `op:gc-answers` when it releases the question, so an outbound
            // gc-answers releases a question we asked and decrements
            // our outbound answers (CapTP spec § op:gc-answers; Goblins sends
            // `cmd-send-gc-answer` from its question will-handler).
            try session.checkGcAnswerDecrement(self.allocator, &self.outbound_answers, gc_answer.positions);
        },
        .listen => |listen| {
            if (!self.features.pipelining) return Error.FeatureNotNegotiated;
            try validateDeliverOrListenTarget(self, listen.target, .sent);
            try validateListenListener(self, listen.listener, .sent);
        },
        // `op:get` / `op:index` / `op:untag` name a receiver like a deliver
        // target: it must be something we hold (ADR-0050).
        .get => |get| {
            try checkOutboundAnswerPosition(self, get.answer);
            try validateReference(self, get.receiver, .sent, .held_import);
        },
        .index => |index| {
            try checkOutboundAnswerPosition(self, index.answer);
            try validateReference(self, index.receiver, .sent, .held_import);
        },
        .untag => |untag| {
            if (self.captp_version == .v1_0) return Error.UnexpectedMessage;
            try checkOutboundAnswerPosition(self, untag.answer);
            try validateReference(self, untag.receiver, .sent, .held_import);
        },
        // `op:abort` carries no send-side validation. Listing the remaining
        // no-op kinds explicitly (rather than `else`) makes a new
        // `model.Message` kind fail to compile until its send-side validation
        // is classified here — the silent-drop that produced the wire-delta
        // bug cannot recur.
        .abort => {},
    }
}

pub fn validateRecv(self: *Session, message: model.Message, introduced: *IntroducedImports) !void {
    // State admission is gated at the dispatch head (`admitInState`). Inbound
    // `op:start-session` keeps its negotiating-only / no-duplicate rule and
    // also checks the partner's CapTP version against this session's profile.
    switch (message) {
        .start_session => |ss| try validateStartSession(self, ss, .remote_received),
        .deliver => |deliver| try validateInboundDeliverAny(self, deliver, introduced),
        // No V1.0 wire-resolve refusal here: this path also validates the
        // engine-synthesized semantic `Resolve` from a resolver callback;
        // the wire refusal lives in `validateRecvView`.
        .resolve => |resolve| try validateInboundResolve(self, resolve, introduced),
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
        .get => |get| try validateProjectionOp(self, get.receiver, get.answer),
        .index => |index| try validateProjectionOp(self, index.receiver, index.answer),
        .untag => |untag| {
            if (self.captp_version == .v1_0) return Error.UnexpectedMessage;
            try validateProjectionOp(self, untag.receiver, untag.answer);
        },
        // `op:abort` is always admitted and carries no kind-specific rule.
        else => {},
    }
}

fn validateOutboundDeliver(self: *Session, deliver: model.Deliver) !void {
    if (deliver.answer) |answer| try checkOutboundAnswerPosition(self, answer);
    try validateDeliverOrListenTarget(self, deliver.target, .sent);
    if (deliver.resolve_me_desc) |reference| {
        // Next has no inline resolver field: answered operations are followed
        // by their mandatory op:listen. Refuse before apply installs `answer`;
        // leaving this to the codec would commit session state for a message
        // that can never be encoded.
        if (self.captp_version == .next) return Error.UnexpectedMessage;
        try validateReference(self, reference, .sent, .held_import);
    }
    try validateArguments(self, deliver.args, 0, .held);
}

/// One locally chosen answer position names one outstanding question until a
/// matching `op:gc-answers` release removes it. Reuse would alias two distinct
/// calls onto one settlement row.
fn checkOutboundAnswerPosition(self: *const Session, answer: model.AnswerPosition) Error!void {
    if (self.outbound_answers.contains(answer)) return Error.UnexpectedMessage;
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

/// The record the inbound argument walk hands to apply: every far mention the
/// message introduces, plus the distinct-new tally the import cap is enforced
/// against. One walk serves both consumers, so an inbound deliver/resolve's
/// argument bytes are walked once here and never re-walked by apply
/// (`applyRecvShared` consumes `mentions` instead of traversing the borrowed
/// view again).
///
/// The import cap must hold at *validate* time: apply commits the answer row
/// before it installs imports, so an `ImportCapExceeded` first discovered in
/// apply would break the all-or-nothing contract in `apply.zig`. The walk
/// counts prospective installs against `SessionLimits.max_imports` with the
/// same rules `registerImport` applies (bootstrap excluded, already-held ids
/// are refcount refreshes, one new id counts once however often the message
/// repeats it). `mentions` records every non-bootstrap far mention —
/// repeats included, each is one wire-delta retain apply must take. Lazy: a
/// message that carries no far reference never allocates. The record spine
/// backs it with the per-turn `recv_scratch` arena (no deinit; the turn reset
/// reclaims it); a validation-only caller backs it with the gpa and pairs it
/// with `deinit`.
pub const IntroducedImports = struct {
    allocator: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(model.ImportPosition, void) = .empty,
    mentions: std.ArrayListUnmanaged(model.ImportPosition) = .empty,
    /// Promise-shaped far mentions that require the next profile's one private
    /// shortening subscription. Repeats are retained here; the session table
    /// deduplicates by live import identity when the engine schedules them.
    promise_mentions: std.ArrayListUnmanaged(model.ImportPosition) = .empty,
    /// What is left of this message's equality-comparison allowance, spent by
    /// the set-uniqueness fold. It rides the per-turn record rather than the
    /// session because it is turn state: one record is built per recv entry
    /// point and threaded down the same walk that reaches the fold, so the
    /// bound is per message (a frame's many sets share one allowance) at no
    /// per-session footprint cost. Refilled by `init`, which every turn calls.
    compare_budget: model.equality.CompareBudget,

    pub fn init(allocator: std.mem.Allocator, limits: SessionLimits) IntroducedImports {
        return .{
            .allocator = allocator,
            .compare_budget = .init(limits.max_compare_visits),
        };
    }

    pub fn deinit(self: *IntroducedImports) void {
        self.seen.deinit(self.allocator);
        self.mentions.deinit(self.allocator);
        self.promise_mentions.deinit(self.allocator);
    }

    fn noteFar(self: *IntroducedImports, s: *Session, far: model.FarRef) RecvViewError!void {
        const import_position = far.import_position;
        if (import_position.int() == BOOTSTRAP_POSITION) return;
        try self.mentions.append(self.allocator, import_position);
        if (far.kind == .promise) try self.promise_mentions.append(self.allocator, import_position);
        if (s.imports.contains(import_position)) return;
        const gop = try self.seen.getOrPut(self.allocator, import_position);
        if (gop.found_existing) return;
        if (s.imports.len() + self.seen.count() > s.limits.max_imports) {
            return Error.ImportCapExceeded;
        }
    }
};

/// The two rules every partner-named inbound answer position answers to.
///
/// The position is attacker-controlled, so both are refusals rather than
/// assumptions. The range at and above `VIRTUAL_INBOUND_ANSWER_BASE` belongs to
/// session-allocated virtual answers, and a partner claim inside it could fuse
/// its question with one the engine allocated for itself. And an answer names
/// one outstanding question, so reusing a row that is still live — pending, or
/// settled and awaiting `op:gc-answers` — is a protocol violation; refusing it
/// here projects a typed abort, where letting it through left `installAnswer` a
/// no-op and failed later on our own outbound resolve with no abort recorded.
///
/// Every kind that installs an inbound answer calls this: the deliver that
/// carries one, and the three projection ops (ADR-0050), which name an answer
/// of their own and install a row exactly as a deliver does.
fn checkInboundAnswerPosition(self: *Session, answer: model.AnswerPosition) Error!void {
    switch (model.AnswerName.classify(answer.int())) {
        .virtual => return Error.InvalidReference,
        .wire => {},
    }
    if (self.inbound_answers.contains(answer)) return Error.UnexpectedMessage;
}

fn validateInboundDeliverAny(self: *Session, deliver: anytype, introduced: *IntroducedImports) RecvViewError!void {
    if (deliver.answer) |answer| try checkInboundAnswerPosition(self, answer);
    try validateDeliverOrListenTarget(self, deliver.target, .received);
    // A promise target's pipeline path is refused inbound: pancake decomposes
    // every multi-hop pipeline into single-hop links at the *sender*
    // (`engine.pipeline`, the flat-inbound invariant in `pipeline.zig`), and the
    // inbound path reads only the target's `answer_position`, never the path —
    // so a non-empty path names call arguments nothing validates and nothing
    // dispatches. Refusing it fails closed on that ignored sub-structure rather
    // than accepting a frame with an inert, unvalidated payload. Only Cap'n
    // Proto can carry a path on the wire; a Syrup target is always flat.
    if (deliver.target == .promise) {
        const path = deliver.target.promise.path;
        const empty = if (comptime @TypeOf(path) == model.view.PipelinePath)
            try path.isEmpty()
        else
            path.isEmpty();
        if (!empty) return Error.UnexpectedMessage;
    }
    if (deliver.resolve_me_desc) |reference| {
        // The partner is introducing the resolver it wants us to invoke, not
        // referring to an import we already hold. V1.0 registration commits
        // that introduction only after this full deliver has validated.
        try validateReference(self, reference, .received, .introduction);
    }
    try validateInboundArguments(self, deliver.args, 0, introduced);
}

/// Whose message the one reference validator is looking at. A `near` names one
/// of our exports on both paths, but the admission rule differs by direction:
/// our own send needs only a live row (a reserved export may marshal — that
/// first marshal is what grants it), while a partner may only name an export
/// it holds a wire reference to. A reserved-but-ungranted position is refused
/// with the same `InvalidReference` as a nonexistent one, so a partner probing
/// positions cannot learn that a reservation exists (ADR-0074).
const Perspective = enum { sent, received };

/// How the one reference validator treats a `far`. Everything else about a
/// reference is position-independent — `promise`/`broken` are always
/// acceptable, and a `sturdy` always requires the negotiated sturdyref
/// feature — so beyond the `near` perspective rule, the `far` arm is the only
/// axis a position varies on.
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

/// Validate the descriptor role shared by `op:deliver` and `op:listen`
/// targets, not merely the authority behind its integer. On send, a target is
/// one of the partner's exports (`far` -> wire `desc:export`) or an answer we
/// allocated (`promise` -> wire `desc:answer`). On receive those roles flip to
/// one of our granted exports (`near`) or an answer the partner allocated
/// (`promise`). A live answer is a row still present in the matching table,
/// pending or settled; `op:gc-answers` is what ends its addressability.
///
/// `anytype` keeps this one rule shared by owned and borrowed inbound paths.
fn validateDeliverOrListenTarget(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
) Error!void {
    switch (perspective) {
        .sent => switch (reference) {
            .far => try validateReference(self, reference, .sent, .held_import),
            .promise => |promise| {
                if (!self.outbound_answers.contains(promise.answer_position)) {
                    return Error.InvalidReference;
                }
            },
            .near, .sturdy, .broken => return Error.InvalidReference,
        },
        .received => switch (reference) {
            .near => try validateReference(self, reference, .received, .held_import),
            .promise => |promise| {
                if (!self.inbound_answers.contains(promise.answer_position)) {
                    return Error.InvalidReference;
                }
            },
            .far, .sturdy, .broken => return Error.InvalidReference,
        },
    }
}

/// Validate `op:listen`'s notification destination in its own descriptor role.
/// We send one of our exports (`near` -> wire `desc:import-*`); a partner sends
/// one of its exports as a fresh import (`far`, decoded from `desc:import-*`).
/// Targets and listener destinations are both references, but they are not
/// interchangeable protocol positions.
fn validateListenListener(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
) Error!void {
    switch (perspective) {
        .sent => switch (reference) {
            .near => try validateReference(self, reference, .sent, .held_import),
            .far, .promise, .sturdy, .broken => return Error.InvalidReference,
        },
        .received => switch (reference) {
            .far => try validateReference(self, reference, .received, .introduction),
            .near, .promise, .sturdy, .broken => return Error.InvalidReference,
        },
    }
}

/// The one reference-position validator. Post perspective-flip (ADR-0010) a
/// decoded `near` names one of our exports; the `near` arm varies by
/// `perspective` and the `far` arm by `far_policy`. Dual-shape over the
/// borrowed view reference and the owned `model.Reference`, like the argument
/// walkers that call it.
fn validateReference(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
    comptime far_policy: FarPolicy,
) Error!void {
    switch (reference) {
        .near => |near| switch (perspective) {
            .sent => if (!self.exports.contains(near.export_position)) return Error.InvalidReference,
            // The pinned bootstrap export is always addressable (ADR-0006);
            // any other export the partner names must carry a wire-count
            // grant — a reference that crossed the wire, or an explicit
            // `registerExport` grant.
            .received => if (near.export_position.int() != BOOTSTRAP_POSITION and
                self.exports.wireHeld(near.export_position) == 0)
                return Error.InvalidReference,
        },
        .far => |far| switch (far_policy) {
            .held_import => if (!self.holdsImport(far.import_position)) return Error.InvalidReference,
            .introduction => switch (model.ImportName.classify(far.import_position.int())) {
                .token => return Error.InvalidReference,
                .wire => {},
            },
        },
        .promise, .broken => {},
        .sturdy => if (!self.features.sturdyref) return Error.FeatureNotNegotiated,
    }
}

fn validateInboundArguments(
    self: *Session,
    args: anytype,
    depth: usize,
    introduced: *IntroducedImports,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        // Forward cursor: one linear pass over the borrowed list region, no
        // per-element `at(i)` re-scan from the start and no `len()` pre-walk.
        var it = args.iterator();
        while (try it.next()) |arg| try validateInboundArgument(self, arg, depth, introduced);
    } else {
        for (args) |arg| try validateInboundArgument(self, arg, depth, introduced);
    }
}

fn validateInboundArgument(
    self: *Session,
    arg: anytype,
    depth: usize,
    introduced: *IntroducedImports,
) RecvViewError!void {
    switch (arg) {
        .reference => |reference| {
            try validateReference(self, reference, .received, .introduction);
            if (reference == .far) try introduced.noteFar(self, reference.far);
        },
        .list => |items| try validateInboundArguments(self, items, depth + 1, introduced),
        .set => |items| {
            try validateInboundArguments(self, items, depth + 1, introduced);
            try checkInboundSetUniqueness(self, items, introduced);
        },
        .tagged => |tagged| try validateInboundArguments(self, tagged.value, depth + 1, introduced),
        .@"struct" => |entries| try validateInboundStructEntries(self, entries, depth + 1, introduced),
        // Exhaustive on purpose: a new Argument arm must decide here whether it
        // can carry a reference. The struct arm above was once missed behind an
        // `else`, which let a struct-wrapped reference dodge this walk entirely.
        .handoff => |handoff| try validateInboundHandoffArgument(self, handoff),
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
    }
}

/// Struct entries carry full argument values, so a reference can arrive inside
/// one; walk every entry's value like a list element. Dual-shape like its
/// callers: the borrowed `model.view.StructEntries` walks its lazy cursor,
/// the owned slice walks directly.
/// A set admits each member once: two Equal elements are two wire encodings of
/// one set, so an inbound duplicate is refused (`DuplicateSetElement`) instead
/// of admitted. The Syrup decoder already refuses this at the byte layer
/// (strictly ascending encoded elements), so in practice this fold is the
/// backstop that holds the same invariant for Cap'n Proto — whose pointer wire
/// form cannot prove uniqueness for free — and for any future codec. It runs
/// on the shared walk, so both the borrowed view path and the owned fallback
/// enforce it identically. Borrowed elements are hashed/compared as views
/// (`viewArgumentHash` / `viewArgumentsEqualBounded`) — scratch holds only the view
/// handles and hash rows, never a `toOwned` materialization. The owned
/// fallback projects through the same spine (`argumentsEqualBounded`) and
/// charges the same per-message budget, so the two arms cannot drift in
/// semantics or in cost. A hash group is confirmed before refusing,
/// so a collision never causes a false refusal. Confirming is not free: two
/// sets compare as multisets, so an equal-hashed pair of width N costs on the
/// order of N² element visits, and the commutative set hash lets a partner
/// build that pair deliberately. Every visit therefore charges the session's
/// per-message budget (`SessionLimits.max_compare_visits`), which refuses
/// loudly rather than grinding. The nesting depth of every element was already
/// bounded by the surrounding walk.
fn checkInboundSetUniqueness(
    self: *Session,
    items: anytype,
    introduced: *IntroducedImports,
) RecvViewError!void {
    const arena = self.recv_scratch.allocator();
    if (comptime @TypeOf(items) == model.view.Args) {
        // Cap'n Proto reads this off the list header; Syrup walks the region to
        // count it. Either way the walk below must agree with it, and the two
        // answers come from different files, so the loop checks rather than
        // trusts.
        const count = try items.len();
        if (count < 2) return;
        // Small sets stay on the stack so the common deliver path never grows
        // `recv_scratch` past its retain limit (a per-turn arena grow would
        // break the flat scratch budget in deliver_set_scratch_budget_test).
        const stack_cap = 8;
        var stack_elements: [stack_cap]model.view.Argument = undefined;
        var stack_rows: [stack_cap]SetHashRow = undefined;
        const elements: []model.view.Argument = if (count <= stack_cap)
            stack_elements[0..count]
        else
            try arena.alloc(model.view.Argument, count);
        const rows: []SetHashRow = if (count <= stack_cap)
            stack_rows[0..count]
        else
            try arena.alloc(SetHashRow, count);
        var it = items.iterator();
        var i: usize = 0;
        while (try it.next()) |element| : (i += 1) {
            // A walk that outruns the count would write past `elements`, and
            // the small arm is a stack array. A walk that falls short would
            // leave rows undefined for the sort to order and then index
            // `elements` by. `model.view`'s own `toOwnedSliceDepth` guards
            // both directions; this fold is the one place that did not.
            if (i >= elements.len) return Error.MalformedMessage;
            elements[i] = element;
            rows[i] = .{ .hash = try model.equality.viewArgumentHash(element), .index = i };
        }
        if (i != elements.len) return Error.MalformedMessage;
        std.mem.sort(SetHashRow, rows, {}, SetHashRow.lessThan);
        var run_start: usize = 0;
        for (rows, 0..) |row, ri| {
            if (row.hash != rows[run_start].hash) run_start = ri;
            for (rows[run_start..ri]) |prior| {
                if (try model.equality.viewArgumentsEqualBounded(
                    elements[prior.index],
                    elements[row.index],
                    .{ .scratch = arena, .budget = &introduced.compare_budget },
                )) {
                    return Error.DuplicateSetElement;
                }
            }
        }
        return;
    }
    // Same per-message allowance as the borrowed arm above: whichever arm a
    // message's sets take, one budget bounds the whole message's confirms.
    try checkOwnedSetUniqueness(arena, items, &introduced.compare_budget);
}

/// One hash row of the set-uniqueness fold: sort by hash so Equal elements
/// land adjacent, confirm with a real compare before refusing.
const SetHashRow = struct {
    hash: u64,
    index: usize,
    fn lessThan(_: void, a: @This(), b: @This()) bool {
        return a.hash < b.hash;
    }
};

/// The owned-slice arm of the set-uniqueness fold, shared by the inbound
/// owned fallback above and the send-side walk (`validateArgument`). The
/// inbound path hands the recv arena (rows die in the turn reset); the send
/// path hands the session gpa (no recv turn brackets a send), so small sets
/// stay on the stack and a spilled row slice is freed here precisely.
/// Confirming charges `budget` per element visit exactly as the borrowed fold
/// does — both folds run the one comparison spine — so a partner-influenced
/// owned tree (a stored relayed resolution) buys bounded work, not trusted
/// work.
fn checkOwnedSetUniqueness(
    scratch: std.mem.Allocator,
    elements: []const model.Argument,
    budget: *model.equality.CompareBudget,
) error{ OutOfMemory, DuplicateSetElement, CompareBudgetExhausted }!void {
    if (elements.len < 2) return;
    const stack_cap = 8;
    var stack_rows: [stack_cap]SetHashRow = undefined;
    const spilled = elements.len > stack_cap;
    const rows: []SetHashRow = if (spilled)
        try scratch.alloc(SetHashRow, elements.len)
    else
        stack_rows[0..elements.len];
    defer if (spilled) scratch.free(rows);
    for (elements, 0..) |element, idx| {
        rows[idx] = .{ .hash = model.equality.argumentHash(element), .index = idx };
    }
    std.mem.sort(SetHashRow, rows, {}, SetHashRow.lessThan);
    var run_start: usize = 0;
    for (rows, 0..) |row, ri| {
        if (row.hash != rows[run_start].hash) run_start = ri;
        for (rows[run_start..ri]) |prior| {
            const equal = model.equality.argumentsEqualBounded(
                &elements[prior.index],
                &elements[row.index],
                .{ .scratch = scratch, .budget = budget },
            ) catch |err| switch (err) {
                // An owned tree projects slice-backed with `.projected`
                // hints, so the lazy-view failure arm cannot fire on it.
                error.MalformedView => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
                error.CompareBudgetExhausted => return error.CompareBudgetExhausted,
            };
            if (equal) return error.DuplicateSetElement;
        }
    }
}

/// Refuse a send-side struct carrying two entries with the same key, the
/// validate-time twin of the codecs' canonical-order refusals (ADR-0003).
/// Sorts a shallow copy of the borrowed key slices so a repeat is an adjacent
/// pair; small structs stay on the stack, a spill is freed here precisely.
fn checkSentStructKeyUniqueness(
    scratch: std.mem.Allocator,
    entries: []const model.StructEntry,
) error{ OutOfMemory, DuplicateStructKey }!void {
    if (entries.len < 2) return;
    const stack_cap = 8;
    var stack_keys: [stack_cap][]const u8 = undefined;
    const spilled = entries.len > stack_cap;
    const keys: [][]const u8 = if (spilled)
        try scratch.alloc([]const u8, entries.len)
    else
        stack_keys[0..entries.len];
    defer if (spilled) scratch.free(keys);
    for (entries, 0..) |entry, i| keys[i] = entry.key;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (keys[1..], 0..) |key, i| {
        if (std.mem.eql(u8, keys[i], key)) return error.DuplicateStructKey;
    }
}

fn validateInboundStructEntries(
    self: *Session,
    entries: anytype,
    depth: usize,
    introduced: *IntroducedImports,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(entries) == model.view.StructEntries) {
        var it = entries.iterator();
        while (try it.next()) |entry| try validateInboundArgument(self, entry.value, depth, introduced);
    } else {
        for (entries) |entry| try validateInboundArgument(self, entry.value, depth, introduced);
    }
}

/// Handoff certificates enter CapTP as nested passable values, not as their
/// own operation. Enforce the negotiated gate and structural floor at that
/// real entry point for both borrowed and owned argument trees.
fn validateHandoffArgument(self: *const Session, handoff: anytype) Error!void {
    if (!self.features.handoff) return Error.FeatureNotNegotiated;
    const value = if (comptime @typeInfo(@TypeOf(handoff)) == .pointer)
        handoff.*
    else
        handoff;
    try session.validateHandoffWellFormed(value);
    const give = switch (value) {
        .give => |give| give,
        .receive => |receive| receive.signed_give,
    };
    try validateHandoffGiftId(self, give.gift_id);
}

/// Enforce the current profile's fixed gift-id domain without narrowing the
/// Goblins-compatible V1.0 profile. Public for bootstrap admission, which must
/// reject before it copies a deposit id or parks an early withdrawal.
pub fn validateHandoffGiftId(self: *const Session, gift_id: []const u8) Error!void {
    if (self.captp_version == .next and gift_id.len != model.HANDOFF_GIFT_ID_BYTES) {
        return Error.MalformedMessage;
    }
}

/// A give is addressed to the local key of the session on which it arrived.
/// Check that claim in session authority before Host can project its locator or
/// queue a dial. A receive embeds the same give on a different session, so it
/// deliberately does not take this Receiver-side check.
fn validateInboundHandoffArgument(self: *const Session, handoff: anytype) Error!void {
    try validateHandoffArgument(self, handoff);
    if (self.captp_version != .next) return;
    const value = if (comptime @typeInfo(@TypeOf(handoff)) == .pointer)
        handoff.*
    else
        handoff;
    switch (value) {
        .give => |give| {
            const local_key = self.localSessionKey() orelse return Error.InvalidHandoffSession;
            if (!std.mem.eql(u8, give.recipient_key, local_key)) return Error.InvalidGift;
        },
        .receive => {},
    }
}

/// How the send-side walker treats a leaf `reference`. Both send paths hold
/// every reference to the same rule, and differ on exactly one arm.
///
/// A deliver's arguments must each name something this session already holds
/// (`.held`). A resolve's fulfill payload exempts the `near` arm
/// (`.near_may_be_first_export`), because resolving an answer with a `.near`
/// is how the application exports that object for the first time: there is no
/// export row yet, and `retainSentExportRef` mints one, admitting the position
/// through `admitExportPositionForMarshal` so it must still be a name in this
/// session's own range.
///
/// The exemption stops at that arm. A `far` names the partner's export on
/// *this* session and nowhere else, so one this session does not hold names
/// nothing here: the fulfill would put `<desc:export N>` on the wire for an
/// export this partner never made. Nothing downstream recovers it. A partner
/// that numbers its exports from zero, as Goblins does, is liable to hold a
/// live and unrelated object at that number, so the reference designates the
/// wrong capability instead of failing; a partner that does not holds nothing
/// there and refuses the whole session. The far arm of the deliver path's
/// rule is what closes it, and it is the import-side twin of the export-range
/// admission `retainSentExportRef` already performs for the `near` arm above.
const SendRefCheck = enum { held, near_may_be_first_export };

/// Validate a send-side argument tree: bound the nesting past
/// `max_nesting_depth`, and check each leaf reference per `ref_check`. The
/// depth bound is the twin of the apply-side `retainSentExportArgs` cap: on
/// both send paths a too-deep locally-built message would otherwise pass
/// validation and then trip `NestingTooDeep` mid-walk in `retainSentExports`,
/// over-retaining every shallow export mention before the refusal and
/// breaching apply's all-or-nothing contract. One walk, one depth threshold,
/// so the cap cannot drift between the deliver and resolve paths. `ref_check`
/// is comptime, so the reference branch folds away per call site.
/// Send-side argument validation allocates bounded scratch for the set /
/// struct-key uniqueness folds (gpa, stack-first), so the walk carries the
/// allocator errors the pure reference checks do not.
const SendArgError = Error || std.mem.Allocator.Error;

/// The pre-commit rule for a locally supplied resolution bound for a store
/// (the relayed-resolution seam, `Peer.applyRelayedResolution`): the same
/// depth bound and set / struct-key uniqueness `validateSend` holds for a
/// resolve's fulfill payload, applied to the one entry point that stores an
/// application value without a send. It carries the resolve arm's reference
/// rule too (`.near_may_be_first_export`), because the stored value reaches
/// this same partner verbatim when the fire carriers encode it: a `far` the
/// store holds is a position this session must hold, exactly as if the
/// application had sent the resolve itself.
///
/// The node's relay already keeps to that rule by construction — a relayed
/// fulfillment naming a bare far object takes the handoff arm
/// (`Node.giftRelayedCapability`) rather than the store, and every other
/// session-scoped shape settles broken (ADR-0009) — so this makes an existing
/// convention a checked one, and catches an embedder that stores through the
/// seam directly.
pub fn validateStoredResolution(self: *Session, resolution: model.Resolution) SendArgError!void {
    switch (resolution) {
        .fulfill => |arg| try validateArgument(self, arg, 0, .near_may_be_first_export),
        .@"break" => {},
    }
}

fn validateArguments(self: *Session, args: []const model.Argument, depth: usize, comptime ref_check: SendRefCheck) SendArgError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| {
        try validateArgument(self, arg, depth, ref_check);
    }
}

fn validateArgument(self: *Session, arg: model.Argument, depth: usize, comptime ref_check: SendRefCheck) SendArgError!void {
    switch (arg) {
        .reference => |reference| switch (ref_check) {
            .held => try validateReference(self, reference, .sent, .held_import),
            // Only the `near` arm is exempt; see `SendRefCheck`.
            .near_may_be_first_export => if (reference != .near)
                try validateReference(self, reference, .sent, .held_import),
        },
        .list => |items| try validateArguments(self, items, depth + 1, ref_check),
        .set => |items| {
            try validateArguments(self, items, depth + 1, ref_check);
            // A duplicate set element refuses here, pre-commit, symmetric with
            // the inbound fold. The encoders refuse byte-equal duplicates too
            // (ADR-0003), but only at encode time in `step`, after
            // `retainSentExports` committed wire-delta retains for a frame
            // that never ships, the same all-or-nothing breach the depth
            // bound above closes. This fold is at least as strict as encode:
            // model-Equal-but-byte-distinct forms (two NaN bit patterns)
            // refuse only here, exactly as they would inbound. No message-wide
            // budget brackets a send, so each fold mints its own allowance —
            // per set rather than per message, which still bounds the one
            // partner-influenced caller (`validateStoredResolution`, a relayed
            // fulfillment) at the same rate the inbound fold charges.
            var compare_budget = model.equality.CompareBudget.init(self.limits.max_compare_visits);
            try checkOwnedSetUniqueness(self.allocator, items, &compare_budget);
        },
        .tagged => |tagged| try validateArguments(self, tagged.value, depth + 1, ref_check),
        .@"struct" => |entries| {
            if (depth + 1 > self.limits.max_nesting_depth) return Error.NestingTooDeep;
            for (entries) |entry| try validateArgument(self, entry.value, depth + 1, ref_check);
            // Duplicate struct keys share the set arm's contract: refuse
            // pre-commit, not at encode.
            try checkSentStructKeyUniqueness(self.allocator, entries);
        },
        // Exhaustive on purpose, see `validateInboundArgument`.
        .handoff => |handoff| try validateHandoffArgument(self, handoff),
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
    }
}
