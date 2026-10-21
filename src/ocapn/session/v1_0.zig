//! V1.0 resolver-callback translation, the session-owned half.
//!
//! OCapN V1.0 has no native `op:resolve`: a caller advertises a resolver
//! capability in a deliver's `resolve_me_desc`, and the answer is later settled
//! by an inbound deliver *to that resolver* rather than by a resolve message.
//! glowcap's engine speaks one resolve-shaped semantics internally (ADR-0006),
//! so the session keeps the links that bridge the two: which of our outbound
//! answers a local resolver export settles, and which resolver import the
//! partner gave us for each of its inbound answers.
//!
//! Only the second of those is V1.0's alone. The outbound half is the
//! version-neutral resolver-export link in `resolver_export.zig`, because an
//! `op:listen` notification settles a listener export by the same wire shape.
//! What stays here is the V1.0-specific mint that pays the out-of-band
//! wire-delta retain a synthesized resolver's mention needs.
//!
//! The links are authoritative session state, so they live on `Session`. This
//! file owns the V1.0 operations over them. The fields
//! (`v1_0_inbound_resolver_link`, a `BiMap` holding both directions, plus
//! `next_virtual_inbound_answer`) stay on `Session`, and `Session` aliases each
//! function below so the call sites read as ordinary methods. The engine's
//! encode-side V1.0 hooks live separately in `engine/v1_0.zig`. This is only the
//! session bookkeeping they drive.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;

/// A partner resolver link whose allocations and collision checks are complete
/// but whose capability authority has not moved. The frame's shared
/// introduced-import transaction takes the resolver retain. This value owns the
/// answer/link half and commits it only after the queue or event destination is
/// also secured, adopting that retain as the session's: the callback that
/// settles the answer releases it beside itself, and no caller may spend it
/// first.
pub const PreparedInboundResolver = struct {
    answer: model.AnswerName,
    resolver_import: model.ImportPosition,
    virtual_answer: ?model.VirtualAnswer = null,

    pub fn commit(self: PreparedInboundResolver, target: *Session) void {
        if (self.virtual_answer) |virtual| {
            @import("deliver_resolver.zig").commitVirtualInboundAnswer(target, virtual);
            target.commitFreshInboundAnswerNamed(self.answer);
        }
        target.v1_0_inbound_resolver_link.putAssumeNoClobber(
            self.answer,
            self.resolver_import,
        );
        target.adoptImportRetain(self.resolver_import);
    }
};

/// Whether this session's negotiated CapTP version is OCapN V1.0, which has no
/// native `op:resolve` and therefore needs resolver-callback translation.
pub fn needsV1_0Translation(self: *const Session) bool {
    return self.captp_version == .v1_0;
}

/// Mint a synthesized V1.0 resolver export for `answer` and commit, in one
/// place, the whole wire-delta accounting its on-wire mention requires:
/// allocate the export, install the answer-to-resolver link, and take the
/// export's wire-delta retain. The V1.0 encode hooks
/// (`engine.outbound.encoded.admit` for an answered deliver,
/// `prepareProjectionListener` for a projection listener) put the
/// resolver mention on the wire *outside* `recordSend`'s export accounting,
/// so this is the single owner of that accounting, both hooks route through
/// it rather than restating the three steps and risking drift from
/// `applySend`. All-or-none: a failure after the export is minted rolls it
/// back, since it was never handed to the partner. Returns the minted
/// resolver's near reference.
///
/// It binds an `answer` whose row the projection's record already installed,
/// so it shares `bindFreshResolverExport`, which writes both rows, and its
/// rollback rather than the whole `nominateResolverExport` verb.
pub fn mintOutboundResolver(self: *Session, answer: model.AnswerPosition) !model.NearRef {
    const resolver_export = try self.bindFreshResolverExport(answer, .object, 1);
    return .{ .export_position = resolver_export, .kind = .object };
}

/// Record that the partner's inbound `answer` is resolved via their resolver
/// import `resolver_import` (advertised in the deliver's `resolve_me_desc`).
/// All-or-none: a failure on either map put rolls back everything already
/// committed, the import retain and the forward entry, so no half-installed
/// resolver row survives.
pub fn installInboundResolver(self: *Session, answer: model.AnswerName, resolver_import: model.ImportPosition) !void {
    try self.imports.prepareRetain(
        self.allocator,
        resolver_import,
        self.limits.max_imports,
    );
    const prepared = try prepareInboundResolver(self, answer, resolver_import, null);
    self.imports.retainAssumeCapacity(resolver_import);
    prepared.commit(self);
}

/// Prepare a fresh answer-to-resolver link. `virtual_answer` is present only
/// for the V1.0 resolver-only call shape. Its answer row and cursor advance are
/// part of the same eventual commit. Existing pairs are refused rather than
/// evicted: either collision names authority already accepted from an earlier status-allow: event or source ordering
/// frame.
pub fn prepareInboundResolver(
    self: *Session,
    answer: model.AnswerName,
    resolver_import: model.ImportPosition,
    virtual_answer: ?model.VirtualAnswer,
) !PreparedInboundResolver {
    if (self.v1_0_inbound_resolver_link.getByKey(answer) != null or
        self.v1_0_inbound_resolver_link.getByValue(resolver_import) != null)
        return error.UnexpectedMessage;

    if (virtual_answer) |virtual| {
        std.debug.assert(answer == .virtual and answer.virtual == virtual);
        try self.prepareFreshInboundAnswerNamed(answer);
    }
    try self.v1_0_inbound_resolver_link.ensureUnusedCapacity(self.allocator, 1);
    return .{
        .answer = answer,
        .resolver_import = resolver_import,
        .virtual_answer = virtual_answer,
    };
}

/// The partner's resolver import for an inbound `answer`, if one was
/// advertised, the target our outbound resolution deliver addresses.
pub fn resolverForInboundAnswer(self: *const Session, answer: model.AnswerName) ?model.ImportPosition {
    return self.v1_0_inbound_resolver_link.getByKey(answer);
}

/// The inbound `answer` a resolver import was installed for, the reverse
/// of `resolverForInboundAnswer`. Used by bootstrap-fetch detection when the
/// V1.0 resolver-only pattern has no wire answer-position.
pub fn answerForResolverImport(self: *const Session, resolver_import: model.ImportPosition) ?model.AnswerName {
    return self.v1_0_inbound_resolver_link.getByValue(resolver_import);
}
