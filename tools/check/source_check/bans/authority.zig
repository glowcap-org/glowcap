//! Ban rows: the one writer of the Host's callback latch, id counter, and
//! vow rows.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// `CallbackLatch` is the one writer of the Host's reentrancy latch. A site
/// that sets or clears the flag by hand can unlatch an outer holder.
pub const callback_latch_owner: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/driver/core/host/admission.zig"} } },
        .kind = .forbid,
        .needles = &.{"callback_latch.held"},
        .check = "callback-latch-owner",
        .why = "hold the Host's callback latch through CallbackLatch.hold so every holder restores the state it found",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"callback_latch.held"},
        .check = "callback-latch-owner",
        .why = "hold the Host's callback latch through CallbackLatch.hold so every holder restores the state it found",
    },
};

/// `IdIssuer` alone advances an id counter, so an id is spent only when its
/// operation commits and the counter cannot overflow.
pub const id_issuer_owner: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/foundation/id_issuer.zig"} } },
        .kind = .forbid,
        .needles = &.{"_ids.next"},
        .check = "id-issuer-owner",
        .why = "peek and commit ids through IdIssuer so a refusal spends nothing and the counter never overflows",
    },
};

/// `settlement.retireRow` is the one exit for a published Host vow row, so a
/// row retires only once settled and never strands the pending count.
pub const vow_row_retirement: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/driver", .suffixes = &.{".zig"}, .exclude = &.{"src/driver/core/vows/settlement.zig"} } },
        .kind = .forbid,
        .needles = &.{ ".vows.remove(", ".vows.fetchRemove(" },
        .check = "vow-row-retirement",
        .why = "retire a Host vow row through settlement.retireRow so only a settled row leaves the table",
    },
};
