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
//! *answer* asks for that callback stays profile-distinct: V1.0 advertises a
//! resolver in the deliver, while next follows the answered operation with a
//! mandatory `op:listen`.
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
    const answer = try self.allocateOutboundAnswer();
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

/// Mint a resolver export whose mention will ride a message recorded outside
/// the ordinary send apply walk. This is the shared accounting seam for V1.0's
/// inline resolver and next's mandatory answer listener: bind the export to the
/// answer and take exactly one wire retain for the resolver mention.
pub fn mintMentionedResolverExport(
    self: *Session,
    answer: model.AnswerPosition,
    kind: model.RefKind,
) !model.ExportPosition {
    // This preparation runs before the answered operation is validated and
    // recorded. Replacing a live link here would corrupt the original answer
    // if recordSend later rejects the new operation for reusing its position.
    if (self.outbound_resolver_link.getByValue(.{ .application_answer = answer }) != null)
        return session.Error.UnexpectedMessage;
    const resolver_export = try bindFreshResolverExport(self, answer, kind);
    errdefer abandonResolverExport(self, resolver_export);
    try self.retainSentExportRef(session.slot.toReference(self.exportSlot(resolver_export).?).?);
    return resolver_export;
}

/// Undo `mintMentionedResolverExport` before its mention reaches the wire.
pub fn abandonMentionedResolverExport(self: *Session, resolver_export: model.ExportPosition) void {
    self.exports.decrement(resolver_export, 1) catch unreachable;
    abandonResolverExport(self, resolver_export);
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
    try self.outbound_resolver_link.put(self.allocator, resolver_export, .{ .application_answer = answer });
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
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse return null;
    return switch (purpose) {
        .application_answer => |answer| answer,
        .local_promise_answer, .node_settling, .retired, .shortening_pending, .shortening_complete => null,
    };
}

pub fn isNodeSettlingResolver(
    self: *const Session,
    resolver_export: model.ExportPosition,
) bool {
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse return false;
    return switch (purpose) {
        .node_settling => true,
        else => false,
    };
}

pub fn installNodeSettlingResolver(
    self: *Session,
    resolver_export: model.ExportPosition,
) !void {
    try self.outbound_resolver_link.put(self.allocator, resolver_export, .{
        .node_settling = .{ .resolver_export = resolver_export },
    });
}

/// Conclude a Node-only settling callback before its deliver event is surfaced
/// to the Host composition hook. The Node still owns the event payload; session
/// authority only retires the one-shot resolver and its promise claim.
/// The deliver route classifier reaches here only after
/// `isNodeSettlingResolver` saw this resolver's link row in the same
/// dispatch, so the lookup below asserts presence and purpose.
pub fn completeNodeSettlingResolverCallback(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse unreachable;
    const node = switch (purpose) {
        .node_settling => |node| node,
        else => unreachable,
    };
    if (node.settling_source) |source| {
        const entry = self.findImportedPromise(source.position) orelse unreachable;
        std.debug.assert(entry.cell.row_id == source.row_id);
        std.debug.assert(entry.settling_listener_claimed);
        std.debug.assert(entry.settling_listener_export == resolver_export);
        std.debug.assert(entry.settling_answer == null);
        std.debug.assert(entry.settling_followers.items.len == 0);
        std.debug.assert(entry.settling_node_claimed);
        entry.settling_listener_claimed = false;
        entry.settling_listener_export = .from(0);
        entry.settling_node_claimed = false;
    }
    self.outbound_resolver_link.replaceValueForKey(resolver_export, .{
        .retired = .{
            .resolver_export = resolver_export,
            .state = .complete,
        },
    });
    releaseRetiredResolverIfUnmentioned(self, resolver_export);
    if (node.settling_source) |source| {
        if (!self.hasImport(source.position)) self.releaseShorteningSourceAuthority(source);
    }
}

/// Drop one Node consumer. An application sharing the callback keeps the wire
/// listener. A Node-only listener becomes a pending retired resolver so one
/// callback already in flight is consumed rather than surfaced.
pub fn retireNodeSettlingResolver(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse return;
    switch (purpose) {
        .node_settling => |node| {
            if (node.settling_source) |source| {
                if (self.findImportedPromise(source.position)) |entry| {
                    if (entry.cell.row_id == source.row_id and
                        entry.settling_listener_claimed and
                        entry.settling_listener_export == resolver_export and
                        entry.settling_node_claimed)
                    {
                        entry.settling_node_claimed = false;
                        if (entry.settling_answer != null) return;
                        std.debug.assert(entry.settling_followers.items.len == 0);
                    }
                }
            }
            self.outbound_resolver_link.replaceValueForKey(resolver_export, .{
                .retired = .{
                    .resolver_export = resolver_export,
                    .settling_source = node.settling_source,
                    .state = .pending,
                },
            });
            releaseRetiredResolverIfUnmentioned(self, resolver_export);
        },
        else => {},
    }
}

/// Retire the resolver for a released application answer without deleting the
/// export while the partner still holds its wire mention. A pending callback
/// remains legal and is consumed by the engine; a completed tombstone rejects
/// duplicates until the partner releases the export mention.
pub fn retireApplicationResolver(
    self: *Session,
    answer: model.AnswerPosition,
    state: session.RetiredResolverState,
    settling_source: ?session.PromiseIncarnation,
) void {
    const resolver_export = self.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }) orelse return;
    self.outbound_resolver_link.replaceValueForKey(resolver_export, .{
        .retired = .{
            .resolver_export = resolver_export,
            .settling_source = settling_source,
            .state = state,
        },
    });
    releaseRetiredResolverIfUnmentioned(self, resolver_export);
}

pub fn retiredResolverState(
    self: *const Session,
    resolver_export: model.ExportPosition,
) ?session.RetiredResolverState {
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse return null;
    return switch (purpose) {
        .retired => |retired| retired.state,
        else => null,
    };
}

/// Record the one legal callback that raced with answer release. The listener
/// claim is concluded without needing the removed answer row.
/// The deliver route classifier reaches here only after
/// `retiredResolverState` saw this resolver's retired link row in the same
/// dispatch, so the lookup below asserts presence and purpose.
pub fn completeRetiredResolverCallback(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse unreachable;
    const retired = switch (purpose) {
        .retired => |retired| retired,
        else => unreachable,
    };
    std.debug.assert(retired.state == .pending);
    clearRetiredSettlingClaim(self, resolver_export, retired.settling_source);
    self.outbound_resolver_link.replaceValueForKey(resolver_export, .{
        .retired = .{
            .resolver_export = resolver_export,
            .settling_source = retired.settling_source,
            .state = .complete,
        },
    });
    releaseRetiredResolverIfUnmentioned(self, resolver_export);
}

/// Release a retired resolver's local baseline once no partner wire mention
/// remains, then remove its purpose tombstone.
pub fn releaseRetiredResolverIfUnmentioned(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.outbound_resolver_link.getByKey(resolver_export) orelse return;
    const retired = switch (purpose) {
        .retired => |retired| retired,
        else => return,
    };
    if (!self.exports.contains(resolver_export)) {
        clearRetiredSettlingClaim(self, resolver_export, retired.settling_source);
        std.debug.assert(self.outbound_resolver_link.removeByKey(resolver_export));
        return;
    }
    if (self.exports.wireHeld(resolver_export) != 0) return;
    clearRetiredSettlingClaim(self, resolver_export, retired.settling_source);
    self.releaseUnsharedExport(resolver_export);
    std.debug.assert(self.outbound_resolver_link.removeByKey(resolver_export));
}

fn clearRetiredSettlingClaim(
    self: *Session,
    resolver_export: model.ExportPosition,
    source_in: ?session.PromiseIncarnation,
) void {
    const source = source_in orelse return;
    const entry = self.findImportedPromise(source.position) orelse return;
    if (entry.cell.row_id != source.row_id or
        !entry.settling_listener_claimed or
        entry.settling_listener_export != resolver_export)
        return;
    std.debug.assert(entry.settling_answer == null);
    std.debug.assert(entry.settling_followers.items.len == 0);
    std.debug.assert(!entry.settling_node_claimed);
    entry.settling_listener_claimed = false;
    entry.settling_listener_export = .from(0);
    if (!self.hasImport(source.position)) self.releaseShorteningSourceAuthority(source);
}
