//! Resolver exports: the link binding one of our exports to the outbound
//! answer it settles.
//!
//! A *resolver export* is an export of ours whose settlement is one of our own
//! outbound answers. An inbound `op:deliver` to it carrying
//! `['fulfill|'break, payload]` is the partner settling that answer, not a call
//! on a local object, so the engine surfaces it as a semantic `Resolve`.
//!
//! Two mints produce one and both settle by that same wire shape: the OCapN
//! V1.0 resolver callback advertised in a deliver's `resolve_me_desc`
//! (ADR-0010), and the listener export an outbound `op:listen` nominates
//! (ADR-0095). So this table is version-neutral rather than a V1.0
//! compatibility layer, and ADR-0095 argues that from the spec text. How an
//! *answer* settles stays profile-distinct and lives elsewhere: the V1.0 half
//! in `v1_0.zig`, the next profile's `op:resolve` fold in the engine's
//! outbound path.
//!
//! The link is authoritative session state, so the field
//! (`outbound_resolver_link`, a `BiMap` holding both directions) stays on
//! `Session`; this file owns the operations over it, and `Session` aliases each
//! one so call sites read as ordinary methods.

const std = @import("std");

const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;

/// A resolver export and the outbound answer it settles, reserved together by
/// `nominateResolverExport`.
pub const ResolverNomination = struct {
    resolver_export: model.ExportPosition,
    answer: model.AnswerPosition,
};

/// Reserve a fresh object export bound to a fresh outbound answer, and install
/// that answer. The answer is installed here rather than by the caller after
/// its send because a notification naming an answer we do not hold is refused
/// by `validateInboundResolve`, and that refusal aborts the session.
/// All-or-none, so a failure leaves no export row, no link, and no answer.
///
/// `v1_0.mintOutboundResolver` binds an answer its own caller already owns, so
/// it shares only `bindFreshResolverExport` below.
pub fn nominateResolverExport(self: *Session) !ResolverNomination {
    const answer = self.allocateOutboundAnswer();
    const resolver_export = try bindFreshResolverExport(self, answer, .object);
    errdefer abandonResolverExport(self, resolver_export);
    try self.installOutboundAnswer(answer);
    return .{ .resolver_export = resolver_export, .answer = answer };
}

/// Allocate a fresh export of `kind` and link it to `answer` as that answer's
/// resolver. All-or-none; a caller whose own later step fails rolls back with
/// `abandonResolverExport` while the export is still unmentioned.
pub fn bindFreshResolverExport(
    self: *Session,
    answer: model.AnswerPosition,
    kind: model.RefKind,
) !model.ExportPosition {
    const resolver_export = switch (kind) {
        .object => try self.allocateExport(),
        .promise => try self.allocatePromiseExport(),
    };
    errdefer self.releaseUnsharedExport(resolver_export);
    try installOutboundResolver(self, answer, resolver_export);
    return resolver_export;
}

/// Undo a `bindFreshResolverExport` whose export never reached the partner.
/// Only valid while the export is still at its count-1 reservation, which is
/// what the single-decrement `releaseUnsharedExport` needs to remove the row.
pub fn abandonResolverExport(self: *Session, resolver_export: model.ExportPosition) void {
    std.debug.assert(removeOutboundResolver(self, resolver_export));
    self.releaseUnsharedExport(resolver_export);
}

/// Undo a whole `nominateResolverExport` whose send failed: the export, the
/// link, and the installed answer together, so nothing of the nomination
/// survives. Same window as the halves it composes — the export unmentioned,
/// the answer row still the pending installation the nomination made.
pub fn abandonResolverNomination(self: *Session, nomination: ResolverNomination) void {
    abandonResolverExport(self, nomination.resolver_export);
    self.abandonOutboundAnswer(nomination.answer);
}

/// Record that our outbound `answer` is settled by an inbound deliver to local
/// export `resolver_export`. Committed once the message carrying that export —
/// a V1.0 deliver's `resolve_me_desc`, or an `op:listen`'s listener — is
/// accepted. The `BiMap` holds both directions in lockstep, all-or-none, so no
/// half-installed link can survive a failure. Re-installing an answer's
/// resolver replaces the whole link, evicting the stale export the answer
/// previously bound.
pub fn installOutboundResolver(self: *Session, answer: model.AnswerPosition, resolver_export: model.ExportPosition) !void {
    // The `BiMap` keeps both directions in lockstep and evicts any prior export
    // that shared this answer, so re-installing an answer's resolver replaces
    // the whole link with no half-installed row surviving a failure.
    try self.outbound_resolver_link.put(self.allocator, resolver_export, answer);
}

/// Drop the link keyed on `resolver_export`, returning whether one was there.
/// The rollback half of `installOutboundResolver`, for a caller whose later
/// step failed and whose export never reached the partner.
pub fn removeOutboundResolver(self: *Session, resolver_export: model.ExportPosition) bool {
    return self.outbound_resolver_link.removeByKey(resolver_export);
}

/// Our outbound `answer` an inbound deliver to `resolver_export` settles, if
/// that export is a resolver, the signal to translate the inbound deliver into
/// a semantic `Resolve`.
pub fn answerForResolverExport(self: *const Session, resolver_export: model.ExportPosition) ?model.AnswerPosition {
    return self.outbound_resolver_link.getByKey(resolver_export);
}
