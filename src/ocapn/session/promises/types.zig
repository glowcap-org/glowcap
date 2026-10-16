//! Representation vocabulary for resolver links and imported promises.
//!
//! These types carry state but perform no transition. The resolver and
//! imported-promise operation modules own mutation, Session embeds the values.

const std = @import("std");
const model = @import("model");

const answers = @import("../answers/store.zig");
const bimap = @import("../bimap.zig");

pub const PromiseIncarnation = struct {
    position: model.ImportPosition,
    row_id: u64,
};

pub const RetiredResolverState = enum {
    pending,
    complete,
};

/// Resolver export whose application answer is gone while its wire mention may
/// still be held or invoked.
pub const RetiredResolver = struct {
    resolver_export: model.ExportPosition,
    settling_source: ?PromiseIncarnation = null,
    state: RetiredResolverState,
};

pub const NodeSettlingResolver = struct {
    resolver_export: model.ExportPosition,
    settling_source: ?PromiseIncarnation = null,
};

/// The answer pairing is authority. Trace state is temporary scratch in the
/// existing purpose row, excluded from the reverse map's identity words.
pub const LocalPromiseAnswer = struct {
    name: model.AnswerName,
    gc_next: ?model.ExportPosition = null,
    gc_mark: bool = false,
    /// Node-adopted payload occurrences waiting before Session recording.
    staging_owners: u32 = 0,
};

comptime {
    if (@sizeOf(LocalPromiseAnswer) > @sizeOf(RetiredResolver))
        @compileError("local promise trace scratch must fit the existing resolver-purpose union");
}

pub const ResolverPurpose = union(enum) {
    forwarding: @import("../forwarding.zig").ForwardedReply,
    application_answer: model.AnswerPosition,
    local_promise_answer: LocalPromiseAnswer,
    node_settling: NodeSettlingResolver,
    retired: RetiredResolver,
    shortening_pending: PromiseIncarnation,
    shortening_complete: PromiseIncarnation,

    /// The words an identity-keyed table hashes and compares. The first
    /// names the arm and its flags, the rest carry its positions, so two
    /// purposes with equal words are one purpose.
    pub fn identityWords(self: ResolverPurpose) [4]u64 {
        return switch (self) {
            .forwarding => |forwarding| .{ 6, forwarding.target.name.identityKey(), forwarding.target.row_id, forwarding.resolver_export.int() },
            .application_answer => |answer| .{ 0, @backingInt(answer), 0, 0 },
            .local_promise_answer => |local| .{ 1, local.name.identityKey(), 0, 0 },
            .node_settling => |node| settlingWords(2, node.resolver_export, node.settling_source),
            .retired => |retired| settlingWords(
                3 | (@as(u64, @backingInt(retired.state)) << 4),
                retired.resolver_export,
                retired.settling_source,
            ),
            .shortening_pending => |incarnation| .{ 4, @backingInt(incarnation.position), incarnation.row_id, 0 },
            .shortening_complete => |incarnation| .{ 5, @backingInt(incarnation.position), incarnation.row_id, 0 },
        };
    }

    /// A node-settling or retired resolver serves no answer or promise, so
    /// the export it holds is its only name and it takes no reverse row in
    /// the outbound link.
    pub fn namedKey(self: ResolverPurpose) ?model.ExportPosition {
        return switch (self) {
            .forwarding => |forwarding| forwarding.resolver_export,
            .node_settling => |node| node.resolver_export,
            .retired => |retired| retired.resolver_export,
            .application_answer, .local_promise_answer, .shortening_pending, .shortening_complete => null,
        };
    }

    fn settlingWords(arm: u64, resolver_export: model.ExportPosition, source: ?PromiseIncarnation) [4]u64 {
        const incarnation = source orelse return .{ arm, @backingInt(resolver_export), 0, 0 };
        return .{ arm | (1 << 3), @backingInt(resolver_export), @backingInt(incarnation.position), incarnation.row_id };
    }
};

/// The resolver export is ours. The answer positions inside a purpose are the
/// peer's words, so the purpose side hashes under the session secret.
pub const OutboundResolverLink = bimap.BiMap(model.ExportPosition, ResolverPurpose, .local, .wire);
pub const InboundResolverLink = bimap.BiMap(model.AnswerName, model.ImportPosition, .wire, .wire);

/// Listen/settle cell embedded only by `ImportedPromise`.
pub const PromiseListenCell = struct {
    listeners: answers.ListenerList = .empty,
    resolution: ?answers.StoredResolution = null,
    /// Row identity for queued fire carriers. No default: registration stamps.
    row_id: u64,
};

/// Session metadata for one imported promise. Every next-profile remote promise
/// uses the shortening fields. A non-null host additionally marks a promise
/// introduced through third-party handoff.
pub const ImportedPromise = struct {
    /// Interned in Session's key arena.
    host: ?[]const u8,
    cell: PromiseListenCell,
    /// A self-edge means shortening is pending. A completed edge is stable.
    shortening_target: model.ImportPosition,
    /// Whether the stable edge owns the retain its callback introduced on
    /// `shortening_target` (`shortening.complete` adopted it), which the
    /// closure on this source's final release spends. An edge completed after
    /// its source was already released owns none: the engine released that
    /// retain in the callback's own transaction.
    shortening_target_retained: bool = false,
    /// Wire subscription modes already sent for this imported incarnation.
    sent_listen_modes: u2 = 0,
    settling_listener_claimed: bool = false,
    settling_listener_export: model.ExportPosition = .from(0),
    settling_answer: ?model.AnswerPosition = null,
    settling_followers: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,
    settling_node_claimed: bool = false,
};
