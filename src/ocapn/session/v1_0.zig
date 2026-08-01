//! V1.0 resolver-callback translation, the session-owned half.
//!
//! OCapN V1.0 has no native `op:resolve`: a caller advertises a resolver
//! capability in a deliver's `resolve_me_desc`, and the answer is later settled
//! by an inbound deliver *to that resolver* rather than by a resolve message.
//! pancake's engine speaks one resolve-shaped semantics internally (ADR-0010),
//! so the session keeps the links that bridge the two: which of our outbound
//! answers a local resolver export settles, and which resolver import the
//! partner gave us for each of its inbound answers.
//!
//! Only the second of those is V1.0's alone. The outbound half is the
//! version-neutral resolver-export link in `resolver_export.zig`, because an
//! `op:listen` notification settles a listener export by the same wire shape;
//! what stays here is the V1.0-specific mint that pays the out-of-band
//! wire-delta retain a synthesized resolver's mention needs.
//!
//! The links are authoritative session state, so they live on `Session`; this
//! file owns the V1.0 operations over them. The fields
//! (`v1_0_inbound_resolver_link`, a `BiMap` holding both directions, plus
//! `next_virtual_inbound_answer`) stay on `Session`, and `Session` aliases each
//! function below so the call sites read as ordinary methods. The engine's
//! encode-side V1.0 hooks live separately in `engine/v1_0.zig`; this is only the
//! session bookkeeping they drive.

const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;

/// Whether this session's negotiated CapTP version is OCapN V1.0, which has no
/// native `op:resolve` and therefore needs resolver-callback translation.
pub fn needsV1_0Translation(self: *const Session) bool {
    return self.captp_version == .v1_0;
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
///
/// It binds an `answer` the encode hook already holds, so it shares
/// `bindFreshResolverExport` and its rollback rather than the whole
/// `nominateResolverExport` verb.
pub fn mintOutboundResolver(self: *Session, answer: model.AnswerPosition) !model.ExportPosition {
    const resolver_export = try self.bindFreshResolverExport(answer, .promise);
    errdefer self.abandonResolverExport(resolver_export);
    try self.retainSentExportRef(session.slot.toReference(self.exportSlot(resolver_export).?).?);
    return resolver_export;
}

/// Record that the partner's inbound `answer` is resolved via their resolver
/// import `resolver_import` (advertised in the deliver's `resolve_me_desc`).
/// All-or-none: a failure on either map put rolls back everything already
/// committed — the import retain and the forward entry — so no half-installed
/// resolver row survives.
pub fn installInboundResolver(self: *Session, answer: model.AnswerPosition, resolver_import: model.ImportPosition) !void {
    // The position comes off the wire, and this path installs the import row
    // itself rather than looking one up, so the ordinary reference checks never
    // see it. The range above `REDEEMED_TOKEN_BASE` is the node's, reserved for
    // the ids it hands the application for redeemed capabilities and documented
    // as disjoint from any partner's import. Refuse it here, or a partner's
    // `resolve_me_desc` can name an id into that range and break the one
    // property the range exists to provide.
    if (resolver_import.int() >= session.REDEEMED_TOKEN_BASE) return session.Error.InvalidReference;
    try self.registerImport(resolver_import);
    // The `BiMap` put is all-or-none across both directions, so a failure needs
    // only the import retain rolled back (the one piece the map cannot own). The
    // retain above just succeeded, so the decrement cannot underflow;
    // `unreachable` keeps that construction loud in safe builds.
    self.v1_0_inbound_resolver_link.put(self.allocator, answer, resolver_import) catch |err| {
        self.imports.decrement(resolver_import, 1) catch unreachable;
        return err;
    };
}

/// The partner's resolver import for an inbound `answer`, if one was
/// advertised, the target our outbound resolution deliver addresses.
pub fn resolverForInboundAnswer(self: *const Session, answer: model.AnswerPosition) ?model.ImportPosition {
    return self.v1_0_inbound_resolver_link.getByKey(answer);
}

/// The inbound `answer` a resolver import was installed for, the reverse
/// of `resolverForInboundAnswer`. Used by bootstrap-fetch detection when the
/// V1.0 resolver-only pattern has no wire answer-position.
pub fn answerForResolverImport(self: *const Session, resolver_import: model.ImportPosition) ?model.AnswerPosition {
    return self.v1_0_inbound_resolver_link.getByValue(resolver_import);
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
