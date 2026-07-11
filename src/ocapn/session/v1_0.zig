//! V1.0 resolver-callback translation, the session-owned half.
//!
//! OCapN V1.0 has no native `op:resolve`: a caller advertises a resolver
//! capability in a deliver's `resolve_me_desc`, and the answer is later settled
//! by an inbound deliver *to that resolver* rather than by a resolve message.
//! pancake's engine speaks one resolve-shaped semantics internally (ADR-0010),
//! so the session keeps the small set of links that bridge the two: which of our
//! outbound answers a local resolver export settles, and which resolver import
//! the partner gave us for each of its inbound answers.
//!
//! The links are authoritative session state, so they live on `Session`; this
//! file owns the operations over them. The fields (`v1_0_outbound_resolvers`,
//! `v1_0_outbound_resolver_answers`, `v1_0_inbound_resolvers`,
//! `v1_0_inbound_resolver_answers`, `next_virtual_inbound_answer`) stay on
//! `Session`, and `Session` aliases each
//! function below so the call sites read as ordinary methods. The engine's
//! encode-side V1.0 hooks live separately in `engine/v1_0.zig`; this is only the
//! session bookkeeping they drive.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;

/// Whether this session's negotiated wire profile is OCapN V1.0, which has no
/// native `op:resolve` and therefore needs resolver-callback translation.
pub fn needsV1_0Translation(self: *const Session) bool {
    return self.wire_profile.captp_version == .v1_0;
}

/// Record that our outbound `answer` is resolved via local resolver export
/// `resolver_export` (the id we advertised in `resolve_me_desc`). Committed
/// after the augmented deliver is accepted. Writes the forward row and its
/// answer-keyed inverse in lockstep (see `OutboundResolverAnswers`), all-or-
/// none: a failure on the inverse put rolls the forward row back, so no
/// half-installed link survives. Re-installing an answer's resolver replaces
/// the whole link, dropping the stale forward row with the inverse it served.
pub fn installOutboundResolver(self: *Session, answer: model.AnswerPosition, resolver_export: model.ExportPosition) !void {
    try self.v1_0_outbound_resolvers.put(self.allocator, resolver_export, answer);
    const gop = self.v1_0_outbound_resolver_answers.getOrPut(self.allocator, answer) catch |err| {
        std.debug.assert(self.v1_0_outbound_resolvers.remove(resolver_export));
        return err;
    };
    if (gop.found_existing and gop.value_ptr.* != resolver_export) {
        std.debug.assert(self.v1_0_outbound_resolvers.remove(gop.value_ptr.*));
    }
    gop.value_ptr.* = resolver_export;
}

/// Mint a synthesized V1.0 resolver export for `answer` and commit, in one
/// place, the whole wire-delta accounting its on-wire mention requires:
/// allocate the export, install the answer-to-resolver link, and take the
/// export's wire-delta retain. The V1.0 encode hooks
/// (`engine.v1_0.installResolverForOutboundDeliver` for an answered deliver,
/// `installListenerForOutboundProjection` for a projection listener) put the
/// resolver mention on the wire *outside* `recordSend`/`retainSentExports`,
/// so this is the single owner of that accounting, both hooks route through
/// it rather than restating the three steps and risking drift from
/// `applySend`. All-or-none: a failure after the export is minted rolls it
/// back, since it was never handed to the partner. Returns the minted
/// resolver export position.
pub fn mintOutboundResolver(self: *Session, answer: model.AnswerPosition) !model.ExportPosition {
    const resolver_export = try self.allocateExport();
    errdefer self.releaseUnsharedExport(resolver_export);
    try self.installOutboundResolver(answer, resolver_export);
    // Undo the resolver link (both directions) before the export rollback: the
    // wire-delta retain below can fail (it allocates), and a successful retain
    // would have bumped the export past count 1, where the single-decrement
    // `releaseUnsharedExport` no longer removes it. Removing the link first
    // (errdefers run last-in-first-out) keeps the failure path clean.
    errdefer {
        std.debug.assert(self.v1_0_outbound_resolvers.remove(resolver_export));
        std.debug.assert(self.v1_0_outbound_resolver_answers.remove(answer));
    }
    try self.retainSentExportRef(.{ .near = .{ .export_position = resolver_export, .kind = .promise } });
    return resolver_export;
}

/// Record that the partner's inbound `answer` is resolved via their resolver
/// import `resolver_import` (advertised in the deliver's `resolve_me_desc`).
/// All-or-none: a failure on either map put rolls back everything already
/// committed — the import retain and the forward entry — so no half-installed
/// resolver row survives.
pub fn installInboundResolver(self: *Session, answer: model.AnswerPosition, resolver_import: model.ImportPosition) !void {
    try self.registerImport(resolver_import);
    // The retain above just succeeded, so the rollback decrement cannot
    // underflow; `unreachable` keeps that construction loud in safe builds.
    self.v1_0_inbound_resolvers.put(self.allocator, answer, resolver_import) catch |err| {
        self.imports.decrement(resolver_import, 1) catch unreachable;
        return err;
    };
    self.v1_0_inbound_resolver_answers.put(self.allocator, resolver_import, answer) catch |err| {
        std.debug.assert(self.v1_0_inbound_resolvers.remove(answer));
        self.imports.decrement(resolver_import, 1) catch unreachable;
        return err;
    };
}

/// The partner's resolver import for an inbound `answer`, if one was
/// advertised, the target our outbound resolution deliver addresses.
pub fn resolverForInboundAnswer(self: *const Session, answer: model.AnswerPosition) ?model.ImportPosition {
    return self.v1_0_inbound_resolvers.get(answer);
}

/// The inbound `answer` a resolver import was installed for, the reverse
/// of `resolverForInboundAnswer`. Used by bootstrap-fetch detection when the
/// V1.0 resolver-only pattern has no wire answer-position.
pub fn answerForResolverImport(self: *const Session, resolver_import: model.ImportPosition) ?model.AnswerPosition {
    return self.v1_0_inbound_resolver_answers.get(resolver_import);
}

/// Allocate a fresh virtual inbound answer for V1.0 resolver-only fetches,
/// from the partner-refused range above `VIRTUAL_INBOUND_ANSWER_BASE`.
pub fn allocateInboundAnswer(self: *Session) model.AnswerPosition {
    const id = self.next_virtual_inbound_answer;
    // A plain `+=`, not a wrapping `+%=`: this counter must never wrap. Wrapping
    // past `maxInt(u64)` would re-enter the partner-named range below
    // `VIRTUAL_INBOUND_ANSWER_BASE` and alias a real inbound answer — the exact
    // collision the range reservation exists to prevent. A Debug/ReleaseSafe
    // overflow trap is the correct fail-loud verdict for an invariant that
    // cannot be reached in practice (2^63 virtual fetches on one session).
    self.next_virtual_inbound_answer += 1;
    return model.AnswerPosition.from(id);
}

/// Our outbound `answer` an inbound deliver to `resolver_export` resolves, if
/// that export is a known resolver, the signal to translate the inbound
/// deliver into a semantic `Resolve`.
pub fn answerForResolverExport(self: *const Session, resolver_export: model.ExportPosition) ?model.AnswerPosition {
    return self.v1_0_outbound_resolvers.get(resolver_export);
}
