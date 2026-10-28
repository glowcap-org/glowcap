//! Representation vocabulary for resolver links and imported promises.
//!
//! These types carry state but perform no transition. The resolver and
//! imported-promise operation modules own mutation, Session embeds the values.

const std = @import("std");
const model = @import("model");

const answers = @import("../answers/store.zig");
const foundation = @import("foundation");

pub const PromiseIncarnation = struct {
    position: model.ImportPosition,
    row_id: u64,

    /// No incarnation. Row stamps start at one (`nextStoreStamp`), so stamp
    /// zero names none, and a field that may hold none holds this instead
    /// of an optional's extra word.
    pub const none: PromiseIncarnation = .{ .position = .from(0), .row_id = 0 };

    pub fn some(self: PromiseIncarnation) ?PromiseIncarnation {
        return if (self.row_id == 0) null else self;
    }
};

pub const RetiredResolverState = enum {
    pending,
    complete,
};

/// Resolver export whose application answer is gone while its wire mention may
/// still be held or invoked.
pub const RetiredResolver = struct {
    settling_source: PromiseIncarnation = .none,
    state: RetiredResolverState,
};

pub const NodeSettlingResolver = struct {
    settling_source: PromiseIncarnation = .none,
};

/// The answer pairing is authority. Trace state is temporary scratch in the
/// existing purpose row. A projection's answer is always a virtual one
/// (`local_promise.allocate`), so the row keeps the position and `name`
/// rebuilds the name.
pub const LocalPromiseAnswer = struct {
    answer: model.VirtualAnswer,
    /// The next projection on the collector's mark list. `.from(0)` is none:
    /// the bootstrap position is never a projection.
    gc_next: model.ExportPosition = .from(0),
    /// Node-adopted payload occurrences waiting before Session recording.
    staging_owners: u32 = 0,
    gc_mark: bool = false,
    /// The settlement is stored and its carrier still owed: outbound pressure
    /// refused the carrier at a terminal commit, and the Peer retries it.
    settlement_deferred: bool = false,

    pub fn name(self: LocalPromiseAnswer) model.AnswerName {
        return .fromVirtual(self.answer);
    }
};

/// What a resolver export is for, held on the export's own row
/// (`ExportRow.purpose`, ADR-0038). The row's position is the export, so no
/// arm repeats it. The union is sized for the row every export pays: three
/// words of payload and the tag, and `export_table.ExportRow` pins the sum.
pub const ResolverPurpose = union(enum) {
    /// An ordinary export: an object or promise the application exported.
    /// `ExportTable.purpose` reads it as null, so no caller switches on it.
    none,
    /// A pipelined call forwarded back to its sender settles this question.
    forwarding: answers.AnswerTarget,
    application_answer: model.AnswerPosition,
    local_promise_answer: LocalPromiseAnswer,
    node_settling: NodeSettlingResolver,
    retired: RetiredResolver,
    shortening_pending: PromiseIncarnation,
    shortening_complete: PromiseIncarnation,

    /// Whether a deliver to this export is a resolver callback: every purpose
    /// but an ordinary export and a local promise's projection export.
    pub fn isCallback(self: ResolverPurpose) bool {
        return switch (self) {
            .none, .local_promise_answer => false,
            else => true,
        };
    }
};

comptime {
    if (@sizeOf(ResolverPurpose) != 32) @compileError(std.fmt.comptimePrint(
        "ResolverPurpose is {d} bytes, not 32: an arm wider than three words widens every export row",
        .{@sizeOf(ResolverPurpose)},
    ));
}

/// The V1.0 inbound resolver link: which resolver import the partner gave us
/// for each of its inbound answers. V1.0's alone, because only V1.0
/// advertises a resolver in an answered `op:deliver`; next follows every
/// answered operation with `op:listen` instead.
///
/// It is not folded onto the answer rows: the inbound resolver is installed
/// while classifying an inbound deliver, *before* `recordRecv` installs the
/// answer row, so binding it to the row would break the all-or-nothing
/// apply. The outbound direction has no table: an outbound answer holds the
/// resolver export that settles it and a local promise's virtual inbound row
/// holds its projection export (`AnswerCell.resolverExport`), and the
/// export's row holds what it is for (ADR-0038).
///
/// A resolver export is an ordinary export minted by the session's own
/// allocator (`allocateExport`). It shares the one export namespace with the
/// actor and bootstrap exports, and collision is impossible because the
/// session is the single minter.
///
/// Each answer owns one partner resolver mention. Multiple answers may
/// notify the same capability, so only answer names index this map. The
/// partner chooses those names, which hash under the session secret.
pub const InboundResolverLink = foundation.identity_hash.MapOf(.wire, model.AnswerName, model.ImportPosition);

/// Session metadata for one imported promise under the next profile: its
/// shortening edge and its settling subscription.
pub const ImportedPromise = struct {
    /// Row identity for a `PromiseIncarnation`. No default: registration stamps.
    row_id: u64,
    /// A self-edge means shortening is pending. A completed edge is stable.
    shortening_target: model.ImportPosition,
    /// Whether the stable edge owns the retain its callback introduced on
    /// `shortening_target` (`shortening.complete` adopted it), which the
    /// closure on this source's final release spends. An edge completed after
    /// its source was already released owns none: the engine released that
    /// retain in the callback's own transaction.
    shortening_target_retained: bool = false,
    /// Whether this incarnation has had its one shortening subscription
    /// (`shortening.nominate`). It stays set while the entry lives, so a
    /// later mention cannot install a second listener for the same promise
    /// after the partner released the first resolver's mention.
    shortening_subscribed: bool = false,
    /// Wire subscription modes already sent for this imported incarnation.
    sent_listen_modes: u2 = 0,
    settling_listener_claimed: bool = false,
    settling_listener_export: model.ExportPosition = .from(0),
    settling_answer: ?model.AnswerPosition = null,
    settling_followers: std.ArrayListUnmanaged(answers.OutboundAnswerTarget) = .empty,
    settling_node_claimed: bool = false,
};
