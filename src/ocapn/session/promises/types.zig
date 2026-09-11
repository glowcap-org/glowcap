//! Representation vocabulary for resolver links and imported promises.
//!
//! These types carry state but perform no transition. The resolver and
//! imported-promise operation modules own mutation; Session embeds the values.

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

pub const ResolverPurpose = union(enum) {
    application_answer: model.AnswerPosition,
    local_promise_answer: model.AnswerName,
    node_settling: NodeSettlingResolver,
    retired: RetiredResolver,
    shortening_pending: PromiseIncarnation,
    shortening_complete: PromiseIncarnation,
};

pub const OutboundResolverLink = bimap.BiMap(model.ExportPosition, ResolverPurpose);
pub const InboundResolverLink = bimap.BiMap(model.AnswerName, model.ImportPosition);

/// Listen/settle cell embedded only by `ImportedPromise`.
pub const PromiseListenCell = struct {
    listeners: answers.ListenerList = .empty,
    resolution: ?answers.StoredResolution = null,
    /// Row identity for queued fire carriers. No default: registration stamps.
    row_id: u64,
};

/// Session metadata for one imported promise. Every next-profile remote promise
/// uses the shortening fields; a non-null host additionally marks a promise
/// introduced through third-party handoff.
pub const ImportedPromise = struct {
    /// Interned in Session's key arena.
    host: ?[]const u8,
    cell: PromiseListenCell,
    /// A self-edge means shortening is pending; a completed edge is stable.
    shortening_target: model.ImportPosition,
    /// Whether the stable edge owns the retain its callback introduced on
    /// `shortening_target` (`shortening.complete` adopted it), which the
    /// closure on this source's final release spends. An edge completed after
    /// its source was already released owns none: the engine released that
    /// retain in the callback's own transaction.
    shortening_target_retained: bool = false,
    settling_listener_claimed: bool = false,
    settling_listener_export: model.ExportPosition = .from(0),
    settling_answer: ?model.AnswerPosition = null,
    settling_followers: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,
    settling_node_claimed: bool = false,
};
