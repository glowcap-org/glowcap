//! Resolver exports: an export of ours whose purpose is to settle one of our
//! outbound answers.
//!
//! A *resolver export* is an export of ours whose settlement is one of our own
//! outbound answers. An inbound `op:deliver` to it carrying
//! `['fulfill|'break, payload]` is the partner settling that answer, not a call
//! on a local object, so the engine surfaces it as a semantic `Resolve`.
//!
//! Two mints produce one and both settle by that same wire shape: the OCapN
//! V1.0 resolver callback advertised in a deliver's `resolve_me_desc`
//! (ADR-0006), and the listener export an outbound `op:listen` nominates
//! (ADR-0003). So the purpose is version-neutral rather than a V1.0
//! compatibility layer, and ADR-0003 argues that from the spec text. How an
//! *answer* asks for that callback stays profile-distinct: V1.0 advertises a
//! resolver in the deliver, while next follows the answered operation with a
//! mandatory `op:listen`.
//!
//! The pairing is authoritative session state held in two rows that leave
//! together: the export's row says what the export is for
//! (`ExportRow.purpose`), and the answer's row holds the export back
//! (`AnswerCell.resolverExport`), both under ADR-0038. No table outlives
//! either row.
//! This file owns the operations over both, and `Session` aliases each one so
//! call sites read as ordinary methods.

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
/// All-or-none, so a failure leaves no export row, no purpose, and no answer.
///
/// `v1_0.mintOutboundResolver` binds an answer its own caller already owns, so
/// it shares only `bindFreshResolverExport` below.
pub fn nominateResolverExport(self: *Session) !ResolverNomination {
    const answer = (try self.allocateOutboundAnswer()).position;
    errdefer self.abandonOutboundAnswer(answer);
    try self.installOutboundAnswer(answer);
    const resolver_export = try bindFreshResolverExport(self, answer, .object, 0);
    return .{ .resolver_export = resolver_export, .answer = answer };
}

/// Allocate a fresh export of `kind`, holding `mentions` wire retains beyond
/// its baseline, and link it to `answer` as that answer's resolver: the
/// purpose on the export row, the export on the answer row. The mint is the
/// one fallible step. A caller whose own later step fails rolls back with
/// `abandonResolverExport` while the export is still unmentioned.
///
/// Every caller binds an installed answer no export serves yet: a fresh status-allow: pending state or quoted runtime label
/// answer, or the unlinked one `mintMentionedResolverExport` names. So the
/// pair installs with no eviction and no lookup past the answer row.
pub fn bindFreshResolverExport(
    self: *Session,
    answer: model.AnswerPosition,
    kind: model.RefKind,
    mentions: u64,
) !model.ExportPosition {
    const row = self.outbound_answers.getPtr(answer) orelse unreachable;
    std.debug.assert(row.resolverExport() == null);
    const resolver_export = try self.allocateExportMentioned(kind, mentions);
    self.exports.setPurpose(resolver_export, .{ .application_answer = answer });
    row.setResolverExport(resolver_export);
    return resolver_export;
}

/// Mint the resolver export an admitted deliver's inline mention carries
/// (`engine.outbound.encoded.admit`), ahead of the answer row the same
/// admission installs: the export's row binds it to `answer` and takes
/// exactly one wire retain for the mention, and the answer row takes the
/// export when `applyValidatedSend` installs it (ADR-0038). Returns the near
/// reference the mention carries, projected from the cell the mint
/// registered, so no caller types its kind by hand (ADR-0006). A projection's
/// listener, whose answer row already exists, mints through
/// `v1_0.mintOutboundResolver` instead.
pub fn mintMentionedResolverExport(
    self: *Session,
    answer: model.AnswerPosition,
    kind: model.RefKind,
) !model.NearRef {
    std.debug.assert(!self.outbound_answers.contains(answer));
    const resolver_export = try self.allocateExportMentioned(kind, 1);
    self.exports.setPurpose(resolver_export, .{ .application_answer = answer });
    return .{ .export_position = resolver_export, .kind = kind };
}

/// Undo `mintMentionedResolverExport` before its mention reaches the wire.
pub fn abandonMentionedResolverExport(self: *Session, resolver_export: model.ExportPosition) void {
    // `mintMentionedResolverExport` above retained this position in the same
    // commit/rollback pair, so its undo cannot underflow.
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

/// Undo a whole `nominateResolverExport` whose send failed: the export, its
/// purpose, and the installed answer together, so nothing of the nomination
/// survives. Same window as the halves it composes, the export unmentioned,
/// the answer row still the pending installation the nomination made.
pub fn abandonResolverNomination(self: *Session, nomination: ResolverNomination) void {
    abandonResolverExport(self, nomination.resolver_export);
    self.abandonOutboundAnswer(nomination.answer);
}

/// Record that our outbound `answer` is settled by an inbound deliver to local
/// export `resolver_export`, once the message carrying that export (a V1.0
/// fetch's `resolve_me_desc`) is recorded and `answer`'s row exists. Both
/// rows are present, so the pairing installs without a fallible step. The
/// export is fresh and the answer unlinked, which both rows assert.
pub fn installOutboundResolver(self: *Session, answer: model.AnswerPosition, resolver_export: model.ExportPosition) void {
    const row = self.outbound_answers.getPtr(answer) orelse unreachable;
    std.debug.assert(row.resolverExport() == null);
    self.exports.setPurpose(resolver_export, .{ .application_answer = answer });
    row.setResolverExport(resolver_export);
}

/// What `resolver_export` is for, read from its row: null for a position
/// that is not an export of ours or is an ordinary one. The inbound deliver
/// route classifies a `.near` target by this one read.
pub fn resolverPurpose(self: *const Session, resolver_export: model.ExportPosition) ?session.ResolverPurpose {
    return self.exports.purpose(resolver_export);
}

/// Drop `resolver_export`'s purpose and the answer row's half of the pairing,
/// returning whether the export had one. The rollback half of a bind, for a
/// caller whose later step failed and whose export never reached the
/// partner. An answer row that has already left needs no clearing.
pub fn removeOutboundResolver(self: *Session, resolver_export: model.ExportPosition) bool {
    const purpose = self.exports.clearPurpose(resolver_export) orelse return false;
    if (purpose == .application_answer) {
        if (self.outbound_answers.getPtr(purpose.application_answer)) |row| row.clearResolverExport();
    }
    return true;
}

/// Move `resolver_export`'s purpose to `purpose`, keeping the answer rows
/// in step: the answer the old purpose served drops the export, and the answer status-allow: replacement state identity
/// the new one serves takes it. A settling convergence re-points a listener
/// between answers and the Node consumer this way
/// (`promises/imported/settling.zig`). The export holds a purpose, and an
/// answer the new purpose names holds no resolver yet. status-allow: pending state or quoted runtime label
pub fn replaceResolverPurpose(self: *Session, resolver_export: model.ExportPosition, purpose: session.ResolverPurpose) void {
    const old = self.exports.replacePurpose(resolver_export, purpose);
    if (old == .application_answer) {
        if (self.outbound_answers.getPtr(old.application_answer)) |row| row.clearResolverExport();
    }
    if (purpose == .application_answer) {
        const row = self.outbound_answers.getPtr(purpose.application_answer) orelse unreachable;
        std.debug.assert(row.resolverExport() == null);
        row.setResolverExport(resolver_export);
    }
}

/// The resolver export bound to our outbound `answer`, read from its row.
pub fn resolverExportForAnswer(self: *Session, answer: model.AnswerPosition) ?model.ExportPosition {
    const row = self.outbound_answers.getPtr(answer) orelse return null;
    return row.resolverExport();
}

/// Our outbound `answer` an inbound deliver to `resolver_export` settles, if
/// that export is a resolver, the signal to translate the inbound deliver into
/// a semantic `Resolve`.
pub fn answerForResolverExport(self: *const Session, resolver_export: model.ExportPosition) ?model.AnswerPosition {
    const purpose = self.exports.purpose(resolver_export) orelse return null;
    return switch (purpose) {
        .application_answer => |answer| answer,
        .none, .forwarding, .local_promise_answer, .node_settling, .retired, .shortening_pending, .shortening_complete => null,
    };
}

/// Make a fresh listener export the Node's settling consumer. The export's
/// row is present and bare, as every listener the Node allocates is.
pub fn installNodeSettlingResolver(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    self.exports.setPurpose(resolver_export, .{ .node_settling = .{} });
}

/// Conclude a Node-only settling callback before its deliver event is surfaced
/// to the Host composition hook. The Node still owns the event payload. Session
/// authority only retires the one-shot resolver and its promise claim.
/// The deliver route classifier reaches here only after it read this
/// resolver's node-settling purpose in the same dispatch, so the read below
/// asserts presence and purpose.
pub fn completeNodeSettlingResolverCallback(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.exports.purpose(resolver_export) orelse unreachable;
    const node = switch (purpose) {
        .node_settling => |node| node,
        else => unreachable,
    };
    if (node.settling_source.some()) |source| {
        // `claimSettlingListener` minted this entry beside the purpose the
        // classifier asserted above, so the promise row is present.
        const entry = self.findImportedPromise(source.position) orelse unreachable;
        std.debug.assert(entry.row_id == source.row_id);
        std.debug.assert(entry.settling_listener_claimed);
        std.debug.assert(entry.settling_listener_export == resolver_export);
        std.debug.assert(entry.settling_answer == null);
        std.debug.assert(entry.settling_followers.items.len == 0);
        std.debug.assert(entry.settling_node_claimed);
        entry.settling_listener_claimed = false;
        entry.settling_listener_export = .from(0);
        entry.settling_node_claimed = false;
    }
    const retired: session.RetiredResolver = .{ .state = .complete };
    _ = self.exports.replacePurpose(resolver_export, .{ .retired = retired });
    releaseRetiredIfUnmentioned(self, resolver_export, retired);
    if (node.settling_source.some()) |source| {
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
    const purpose = self.exports.purpose(resolver_export) orelse return;
    switch (purpose) {
        .node_settling => |node| {
            if (node.settling_source.some()) |source| {
                if (self.findImportedPromise(source.position)) |entry| {
                    if (entry.row_id == source.row_id and
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
            const retired: session.RetiredResolver = .{
                .settling_source = node.settling_source,
                .state = .pending,
            };
            _ = self.exports.replacePurpose(resolver_export, .{ .retired = retired });
            releaseRetiredIfUnmentioned(self, resolver_export, retired);
        },
        else => {},
    }
}

/// Retire `resolver_export`, the resolver of an application answer whose row
/// has just left, without deleting the export while the partner still holds
/// its wire mention. A pending callback remains legal and is consumed by the
/// engine. A completed tombstone rejects duplicates until the partner releases
/// the export mention.
pub fn retireApplicationResolver(
    self: *Session,
    resolver_export: model.ExportPosition,
    state: session.RetiredResolverState,
    settling_source: ?session.PromiseIncarnation,
) void {
    const retired: session.RetiredResolver = .{
        .settling_source = settling_source orelse .none,
        .state = state,
    };
    const old = self.exports.replacePurpose(resolver_export, .{ .retired = retired });
    std.debug.assert(old == .application_answer);
    releaseRetiredIfUnmentioned(self, resolver_export, retired);
}

pub fn retiredResolverState(
    self: *const Session,
    resolver_export: model.ExportPosition,
) ?session.RetiredResolverState {
    const purpose = self.exports.purpose(resolver_export) orelse return null;
    return switch (purpose) {
        .retired => |retired| retired.state,
        else => null,
    };
}

/// Record the one legal callback that raced with answer release. The listener
/// claim is concluded without needing the removed answer row.
/// The deliver route classifier reaches here only after it read this
/// resolver's pending retired purpose in the same dispatch, so the read
/// below asserts presence and purpose.
pub fn completeRetiredResolverCallback(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.exports.purpose(resolver_export) orelse unreachable;
    const retired = switch (purpose) {
        .retired => |retired| retired,
        else => unreachable,
    };
    std.debug.assert(retired.state == .pending);
    clearRetiredSettlingClaim(self, resolver_export, retired.settling_source);
    const complete: session.RetiredResolver = .{
        .settling_source = retired.settling_source,
        .state = .complete,
    };
    _ = self.exports.replacePurpose(resolver_export, .{ .retired = complete });
    releaseRetiredIfUnmentioned(self, resolver_export, complete);
}

/// Release a retired resolver's local baseline once no partner wire mention
/// remains, which takes its row and the tombstone on it.
pub fn releaseRetiredResolverIfUnmentioned(
    self: *Session,
    resolver_export: model.ExportPosition,
) void {
    const purpose = self.exports.purpose(resolver_export) orelse return;
    switch (purpose) {
        .retired => |retired| releaseRetiredIfUnmentioned(self, resolver_export, retired),
        else => {},
    }
}

/// The form for a caller that just wrote `retired` onto the row, so the
/// purpose is not read back. One count read says whether the partner still
/// holds a mention: the row is present, because it holds the purpose, and
/// our own baseline retain is one, so anything above it is the partner's.
fn releaseRetiredIfUnmentioned(self: *Session, resolver_export: model.ExportPosition, retired: session.RetiredResolver) void {
    const held = self.exports.count(resolver_export);
    std.debug.assert(held != 0);
    if (held != 1) return;
    clearRetiredSettlingClaim(self, resolver_export, retired.settling_source);
    self.releaseUnsharedExport(resolver_export);
}

fn clearRetiredSettlingClaim(
    self: *Session,
    resolver_export: model.ExportPosition,
    source_in: session.PromiseIncarnation,
) void {
    const source = source_in.some() orelse return;
    const entry = self.findImportedPromise(source.position) orelse return;
    if (entry.row_id != source.row_id or
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
