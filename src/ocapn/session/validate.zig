//! Session validation: the "is this message even allowed?" half of the state
//! machine.
//!
//! The public spine is the three dispatch validators (`validateSend`,
//! `validateRecv`, `validateRecvView`), reached through `Session.recordSend` /
//! `recordRecv` / `recordRecvView`, plus the kind validators the engine runs
//! before its own pre-apply steps (`validateInboundDeliverView` and
//! `validateInboundListen`). The per-kind rules stay here as module-local
//! orchestration. Passable argument/reference validation lives behind
//! `validate/passable.zig`: its one `anytype` walk serves both
//! owned `model.*` values and borrowed `model.view.*` projections, including
//! the `IntroducedImports` record apply consumes. Validators never mutate
//! session authority. The matching mutations live in `apply.zig`.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const passable = @import("validate/passable.zig");
const listen_claims = @import("listen_claims.zig");
const locator_vocabulary = @import("validate/locator_vocabulary.zig");

pub const carriesRouteVocabulary = locator_vocabulary.carriesRouteVocabulary;
pub const requireNegotiatedLocator = locator_vocabulary.requireNegotiated;
pub const parseNegotiatedIdLocator = locator_vocabulary.parseNegotiatedIdLocator;

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const SessionLimits = session.SessionLimits;
const bootstrap_position = session.bootstrap_position;

/// Per-message imports recorded by the Passable walk and consumed by apply.
pub const IntroducedImports = passable.IntroducedImports;

pub fn validateRecvView(self: *Session, body: *const model.view.Body, introduced: *IntroducedImports) !void {
    // State admission is gated at the dispatch head (`admitInState`); this is
    // the kind-specific validation. `op:start-session` keeps its own
    // "negotiating-only" rule because the gate admits it in `open` too, a
    // second handshake there is the kind-specific violation.
    switch (body.*) {
        .start_session => |ss| try validateStartSession(self, ss, .remote_received),
        .deliver => |*deliver| try validateInboundDeliverAny(self, deliver, introduced),
        .resolve => |resolve| {
            if (self.needsV1_0Translation()) return error.UnexpectedMessage;
            try validateInboundResolve(self, resolve, introduced);
        },
        .listen => |listen| try validateInboundListen(self, listen),
        .get => |get| try validateProjectionOp(self, get.receiver, get.answer),
        .index => |index| try validateProjectionOp(self, index.receiver, index.answer),
        // `op:untag` is in the pinned 1.0 draft. The negotiated feature only
        // gates what we send to a partner; a conforming inbound operation is
        // always admitted and answered.
        .untag => |untag| try validateProjectionOp(self, untag.receiver, untag.answer),
        else => {},
    }
}

/// The one inbound `op:get` / `op:index` / `op:untag` rule, shared by both
/// recv representations (`receiver` is the owned or borrowed reference): the
/// receiver names a target in exactly a deliver's position, so the partner
/// must already hold it, and the answer position must be fresh. Without this
/// an inbound projection op with an unheld position would surface to the
/// application unvalidated, an authority gap versus deliver and listen.
fn validateProjectionOp(self: *Session, receiver: anytype, answer: model.AnswerPosition) passable.ReferenceError(@TypeOf(receiver))!void {
    if (self.captp_version == .next) return error.UnexpectedMessage;
    try passable.validateDeliverOrListenTarget(self, receiver, .received);
    try checkInboundAnswerPosition(self, answer);
}

/// The one `op:start-session` kind rule, shared by all three dispatch
/// validators: the session must still be negotiating, this half of the
/// handshake must not have been observed yet (`half` names which flag the status-allow: pending state or quoted runtime label
/// caller's direction owns), and the declared CapTP version must match the
/// session's negotiated profile.
fn validateStartSession(
    self: *Session,
    ss: anytype,
    half: enum { local_sent, remote_received },
) Error!void {
    if (self.state != .negotiating) return error.UnexpectedMessage;
    const already_observed = switch (half) {
        .local_sent => self.handshake_local_sent,
        .remote_received => self.handshake_remote_received,
    };
    if (already_observed) return error.DuplicateStartSession;
    // A hello names the baseline version, not the sender's preference: a peer
    // that stated a preference here would be refused by every partner that did
    // not already share it, which is the opposite of negotiating. The
    // preference travels as a hint and governs the session once both hellos
    // are in. Compared against the baseline rather than the session's own
    // version because by this point the session may already have settled on
    // something else.
    if (ss.captp_version != model.Preference.baseline.captp_version) {
        return error.CaptpVersionMismatch;
    }
    try locator_vocabulary.validateLocatorShape(ss.acceptable_location);
    const preference = try parsePreferenceHintsValidated(ss.acceptable_location.hints);
    const local_preference = switch (half) {
        .local_sent => preference,
        .remote_received => if (self.handshake_local_sent)
            self.local_preference
        else
            self.preferred,
    };
    const other_preference = switch (half) {
        .local_sent => if (self.handshake_remote_received)
            self.partner_preference
        else
            model.Preference.baseline,
        .remote_received => preference,
    };
    try locator_vocabulary.validateStartSession(self, local_preference, other_preference, ss.acceptable_location);
}

/// CapTP preference encoded in start-session location hints. Absent names mean
/// the baseline, and so does a version or codec token this build does not
/// write, such as another build's `next` (ADR-0001): negotiation then settles
/// that axis on what both peers speak. Duplicate names, a non-string value, or
/// an unreadable token is `MalformedMessage`. Session owns this parse so hello
/// validation, apply, and advertised-profile checks cannot drift.
pub fn parsePreferenceHints(hints: anytype) Error!model.Preference {
    try locator_vocabulary.validateHintShape(hints);
    return parsePreferenceHintsValidated(hints);
}

fn parsePreferenceHintsValidated(hints: anytype) Error!model.Preference {
    var out = model.Preference.baseline;
    if (try preferenceHintString(hints, model.transport.hint_captp_version)) |text| {
        out.captp_version = model.CaptpVersion.fromHintToken(text) orelse
            model.Preference.baseline.captp_version;
    }
    if (try preferenceHintString(hints, model.transport.hint_codec)) |text| {
        out.codec = (model.CodecId.fromHintToken(text) catch return error.MalformedMessage) orelse
            model.Preference.baseline.codec;
    }
    if (try preferenceHintString(hints, model.transport.hint_features)) |text| {
        out.features = model.FeatureSet.fromWireString(text) orelse
            return error.MalformedMessage;
    }
    return out;
}

fn preferenceHintString(hints: anytype, name: []const u8) Error!?[]const u8 {
    const value = (try startSessionHintValue(hints, name)) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => return error.MalformedMessage,
    };
}

fn startSessionHintValue(hints: anytype, name: []const u8) Error!?model.HintValue {
    if (comptime @hasDecl(@TypeOf(hints), "findNamed")) {
        return hints.findNamed(name) catch return error.MalformedMessage;
    }
    for (hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

/// Validate an inbound `op:listen`: the pipelining feature gate, the target
/// rule, and the listener rule, the checks the `.listen` dispatch
/// arms run. Public because the engine's listener install
/// (`engine.pipeline.maybeInstallInboundListener`) runs ahead of
/// `recordRecvView` and must validate before it mutates. Both dispatch arms
/// call this same body, so the engine pre-step and the recv path cannot drift.
pub fn validateInboundListen(self: *Session, listen: anytype) RecvViewError!void {
    if (!self.features.pipelining) return error.FeatureNotNegotiated;
    try passable.validateDeliverOrListenTarget(self, listen.target, .received);
    try passable.validateListenListener(self, listen.listener, .received);
}

/// Validate an inbound `op:resolve`. The answer must be one we allocated
/// (an outbound call awaiting its reply), and, symmetrically with a
/// deliver's args, the fulfill payload's references are validated and
/// depth-bounded: a `near` must name one of our exports, a `far` is a fresh
/// introduction, and the payload tree may not nest past `max_nesting_depth`.
/// Without this, a fulfill carrying a `near` to a non-existent export would
/// be accepted while the identical reference in a deliver arg is rejected.
///
/// Public because the engine's V1.0 resolver-callback translation
/// (`Session.recordResolverCallbackResolve`) validates a synthesized resolve
/// with this exact body, minus the wire-`op:resolve` refusal in
/// `validateRecvView`, so the synthesized and canonical resolve paths cannot
/// drift.
pub fn validateInboundResolve(self: *Session, resolve: anytype, introduced: *IntroducedImports) RecvViewError!void {
    const entry = self.outbound_answers.getPtr(resolve.answer) orelse
        return error.InvalidReference;
    // An answer resolves exactly once. A second `op:resolve` for an
    // already-settled answer is a partner protocol violation, not a fresh
    // settlement: reject it (a protocol_error abort) instead of re-mutating
    // status and re-introducing the fulfill's imports.
    if (entry.status() != .pending) return error.UnexpectedMessage;
    switch (resolve.resolution) {
        .fulfill => |arg| try passable.validateInboundArgument(self, &arg, 0, introduced, .resolution),
        .@"break" => {},
    }
}

/// A caller's outbound `op:gc-exports`.
fn validateSentGcExport(self: *Session, gc_export: model.GcExport) !void {
    if (!self.features.wire_delta) return error.FeatureNotNegotiated;
    try session.validateGcExport(gc_export);
    // Our import 0 is the partner's pinned bootstrap, always reachable
    // without a table row (`validateReference` with `.held_import`) and outside
    // wire-delta accounting, so releasing it is releasing an id the
    // table never holds. Refuse loudly rather than put a bootstrap
    // release on the wire (a partner that does account it, the way
    // Goblins does, would tear down its bootstrap export on receipt).
    for (gc_export.positions) |pos| {
        if (pos == bootstrap_position) return error.GcUnderflow;
    }
    // Outbound `op:gc-exports` releases our refs to the partner's
    // exports, decrements the import table, never below the retains
    // the session keeps for releases of its own.
    try session.checkGcExportDecrement(self.allocator, &self.imports, gc_export, self.wire_hash_multiplier);
}

pub fn validateSend(self: *Session, message: model.Message, inventory: session.Inventory) !void {
    // State admission is gated at the dispatch head (`admitInState`). The
    // handshake keeps its negotiating-only / no-duplicate rule here; every
    // other kind carries only its own send-side validation.
    switch (message) {
        .start_session => |ss| try validateStartSession(self, ss, .local_sent),
        .deliver => |deliver| try validateOutboundDeliver(self, deliver, inventory),
        .resolve => |resolve| try validateSentResolutionNamed(
            self,
            .fromWire(resolve.answer),
            resolve.resolution,
            inventory,
        ),
        .gc_export => |gc_export| try validateSentGcExport(self, gc_export),
        .gc_answer => |gc_answer| {
            if (!self.features.wire_delta) return error.FeatureNotNegotiated;
            // The deliverer that allocated an answer position sends
            // `op:gc-answers` when it releases the question, so an outbound
            // gc-answers releases a question we asked and decrements
            // our outbound answers (CapTP spec § op:gc-answers; Goblins sends
            // `cmd-send-gc-answer` from its question will-handler).
            try session.checkGcAnswerDecrement(self.allocator, &self.outbound_answers, gc_answer.positions, self.wire_hash_multiplier);
        },
        .listen => |listen| {
            if (!self.features.pipelining) return error.FeatureNotNegotiated;
            try passable.validateDeliverOrListenTarget(self, listen.target, .sent);
            try passable.validateListenListener(self, listen.listener, .sent);
            try listen_claims.validate(self, listen);
        },
        // `op:get` / `op:index` / `op:untag` name a receiver like a deliver
        // target: it must be something we hold (ADR-0004).
        .get => |get| {
            if (self.captp_version == .next) return error.UnexpectedMessage;
            try checkOutboundAnswerPosition(self, get.answer);
            try passable.validateReference(self, get.receiver, .sent, .held_import, .call);
        },
        .index => |index| {
            if (self.captp_version == .next) return error.UnexpectedMessage;
            try checkOutboundAnswerPosition(self, index.answer);
            try passable.validateReference(self, index.receiver, .sent, .held_import, .call);
        },
        .untag => |untag| {
            if (self.captp_version == .next) return error.UnexpectedMessage;
            if (!self.features.untag) return error.FeatureNotNegotiated;
            try checkOutboundAnswerPosition(self, untag.answer);
            try passable.validateReference(self, untag.receiver, .sent, .held_import, .call);
        },
        // `op:abort` carries no send-side validation. Listing the remaining
        // no-op kinds explicitly (rather than `else`) makes a new
        // `model.Message` kind fail to compile until its send-side validation
        // is classified here, the silent-drop that produced the wire-delta
        // bug cannot recur.
        .abort => {},
    }
}

pub fn validateSentResolutionNamed(
    self: *Session,
    answer: model.AnswerName,
    resolution: model.Resolution,
    inventory: session.Inventory,
) !void {
    // Send-side answers also resolve once; a second settlement cannot publish.
    const entry = self.inbound_answers.getPtr(answer) orelse
        return error.InvalidReference;
    if (entry.status() != .pending) return error.UnexpectedMessage;
    try validateSentResolutionValue(self, resolution, inventory);
}

/// Certify a resolution this session is about to send or store, from the
/// inventory its owner took of it. The fulfillment's own export may be a
/// first mention (`passable.Carrier.resolution`).
pub fn validateSentResolutionValue(
    self: *Session,
    resolution: model.Resolution,
    inventory: session.Inventory,
) passable.SendArgError!void {
    const root: ?*const model.Argument = if (resolution == .fulfill) &resolution.fulfill else null;
    try passable.certifySent(self, inventory, root, .resolution);
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
            if (!self.features.wire_delta) return error.FeatureNotNegotiated;
            try session.validateGcExport(gc_export);
            // Inbound `op:gc-exports` is the partner releasing refs to our
            // exports, decrements the export table. The duplicate-position
            // scratch map is turn-scratch, so it bumps the recv arena and dies
            // with `recordRecvView`'s reset.
            try session.checkGcExportDecrement(self.recv_scratch.allocator(), &self.exports, gc_export, self.wire_hash_multiplier);
        },
        .gc_answer => |gc_answer| {
            if (!self.features.wire_delta) return error.FeatureNotNegotiated;
            // Inbound `op:gc-answers` is the partner GCing a question it
            // asked us to answer, so it releases the inbound answers we
            // created for it (Goblins removes from its `answers` table on
            // `op:gc-answers`). Scratch lives in the recv arena, as above.
            try session.checkGcAnswerDecrement(self.recv_scratch.allocator(), &self.inbound_answers, gc_answer.positions, self.wire_hash_multiplier);
        },
        .listen => |listen| try validateInboundListen(self, listen),
        .get => |get| try validateProjectionOp(self, get.receiver, get.answer),
        .index => |index| try validateProjectionOp(self, index.receiver, index.answer),
        .untag => |untag| try validateProjectionOp(self, untag.receiver, untag.answer),
        // `op:abort` is always admitted and carries no kind-specific rule.
        else => {},
    }
}

fn validateOutboundDeliver(self: *Session, deliver: model.Deliver, inventory: session.Inventory) !void {
    if (self.captp_version == .next and (deliver.answer != null or deliver.resolve_me_desc != null) and deliver.listen_mode == .settling_only) return error.UnexpectedMessage;
    if (deliver.answer) |answer| try checkOutboundAnswerPosition(self, answer);
    try passable.validateDeliverOrListenTarget(self, deliver.target, .sent);
    if (deliver.resolve_me_desc) |reference| {
        if (self.captp_version == .next and (deliver.listen_mode == .settling_only or reference != .near)) return error.UnexpectedMessage;
        try passable.validateReference(self, reference, .sent, .held_import, .call);
    }
    try passable.certifySent(self, inventory, null, .call);
}

/// One locally chosen answer position names one outstanding question until a
/// matching `op:gc-answers` release removes it. Reuse would alias two distinct
/// calls onto one settlement row.
fn checkOutboundAnswerPosition(self: *const Session, answer: model.AnswerPosition) Error!void {
    if (!self.outbound_answers.fresh(answer)) return error.UnexpectedMessage;
}

/// A partner-named answer names one outstanding question, so reusing a row
/// that is still live, pending, or
/// settled and awaiting `op:gc-answers`, is a protocol violation. Refusing it
/// here projects a typed abort, where letting it through left
/// `installInboundAnswerNamed` a no-op and failed later on our own outbound
/// resolve with no abort recorded.
///
/// Every kind that installs an inbound answer calls this: the deliver that
/// carries one, and the three projection ops (ADR-0004), which name an answer
/// of their own and install a row as a deliver does.
fn checkInboundAnswerPosition(self: *Session, answer: model.AnswerPosition) Error!void {
    if (self.inbound_answers.contains(.fromWire(answer))) return error.UnexpectedMessage;
}

fn validateInboundDeliverAny(self: *Session, deliver: anytype, introduced: *IntroducedImports) RecvViewError!void {
    if (self.captp_version == .next and deliver.answer != null and deliver.resolve_me_desc == null) return error.UnexpectedMessage;
    if (deliver.answer) |answer| try checkInboundAnswerPosition(self, answer);
    try passable.validateDeliverOrListenTarget(self, deliver.target, .received);
    if (deliver.resolve_me_desc) |reference| {
        if (self.captp_version == .next and deliver.listen_mode == .settling_only) return error.UnexpectedMessage;
        // Resolver introductions share the argument import transaction.
        switch (reference) {
            .far => |far| try introduced.noteResolver(self, far),
            else => return error.UnexpectedMessage,
        }
    }
    try passable.validateInboundArguments(self, deliver.args, 0, introduced, .call);
}

/// Enforce the fixed gift-id domain on the profile that mints under it, without
/// narrowing the V1.0 profile that has to interoperate. Public for bootstrap
/// admission, which must reject before it copies a deposit id or parks an early
/// withdrawal.
///
/// The draft specifies 32 random bytes and glowcap mints that everywhere, so the
/// rule is right for `next`, where both ends are glowcap's own. It is wrong as
/// an inbound rule for `1.0`: the pinned OCapN suite gives with a seven-byte
/// `my-gift`, and refusing it retires the session before the handoff is read, so
/// `tests.third_party_handoffs` loses its Exporter and Receiver cases to a
/// closed socket. Length is not what makes a gift id safe here either, the
/// signed envelope is the authority, and a short id costs one bounded retry
/// against the fixed-width tag that keeps a partner-chosen length out of
/// coordination state. This follows the same posture as `op:listen`'s operand
/// count, recorded in `conformance/ocapn-findings`: interoperate with the pinned implementations, and record the disagreement rather than settle it here.
pub fn validateHandoffGiftId(self: *const Session, gift_id: []const u8) Error!void {
    try passable.validateHandoffGiftId(self.captp_version, gift_id);
}

/// Validate the destination of a prepared listener fire. Its payload has
/// already passed `validateSentResolutionValue`. This checks the one remaining
/// session-relative name without repeating the payload's allocation-bearing
/// set/struct folds for every fan-out recipient.
pub fn validateListenerFireTarget(self: *Session, listener: model.FarRef) Error!void {
    const reference: model.Reference = .{ .far = listener };
    try passable.validateReference(self, reference, .sent, .held_import, .call);
}
