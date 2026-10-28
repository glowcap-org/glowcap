//! The session's own bookkeeping, checked against the rows it counts.
//!
//! Several facts are kept twice for speed: a counter beside the rows it
//! counts, or a bound beside the charges it adds up. Each verb keeps both in
//! the same turn, and nothing else catches a verb that keeps only one. A
//! counter that drifts from its rows never crashes and never trips a cap. It
//! skips a scan that had work, refuses a partner that fits, or holds a retain
//! nobody will release. `check` walks every row and reports the first fact
//! that disagrees with its counter.
//!
//! Every relation here holds between any two session verbs, mid-conversation
//! included, so a caller may check at any turn boundary. `Session.deinit`
//! checks under runtime safety, which holds every test and fuzz run that
//! tears a session down to these relations. The walk is linear in the
//! session's rows and allocates nothing.
const std = @import("std");
const session = @import("mod.zig");
const answers = @import("answers/store.zig");

const Session = session.Session;

/// One bookkeeping fact that disagrees with the rows it describes.
pub const Violation = error{
    /// An import row is live at a count of zero, which retires it.
    ImportRowRetainsNothing,
    /// An import row says the session keeps more retains than the row holds.
    SessionHeldExceedsCount,
    /// An import row holds back more retains than the session keeps.
    HeldBackExceedsSessionHeld,
    /// An import row holds retains back with no stored resolution holding it.
    HeldBackWithoutHold,
    /// `ImportTable.held_rows` differs from the rows a resolution holds.
    HeldRowsMiscounted,
    /// An import identity names a position with no live row, other than the
    /// bootstrap import, which keeps an identity with no row.
    IdentityWithoutImport,
    /// An import identity has lifted more retains than its row holds.
    LiftedRetainsExceedCount,
    /// A local promise projection names an export that is not its projection.
    ProjectionWithoutExport,
    /// The registry lists a different number of projections than the export
    /// table carries.
    ProjectionsMiscounted,
    /// `local_promise.Registry.deferred` differs from the projections that owe
    /// their settlement carrier.
    DeferredSettlementsMiscounted,
    /// More reachable answer payloads watch a Host promise than
    /// `InboundAnswerTable.host_promises` counts.
    HostPromisesUndercounted,
    /// A payload says its Host promise was notified with no promise marked.
    HostPromiseNotifiedWithoutMark,
    /// The reachable payloads hold more resolution bytes than
    /// `Session.retained_sent_answer_bytes` charges.
    ResolutionBytesUndercounted,
    /// The reachable payloads hold other queued call bytes than
    /// `Session.queued_call_bytes` charges.
    QueuedCallBytesMiscounted,
};

/// The first bookkeeping fact of `self` that disagrees with its rows.
pub fn check(self: *const Session) Violation!void {
    try auditImports(self);
    try auditLocalPromises(self);
    try auditAnswerPayloads(self);
}

fn auditImports(self: *const Session) Violation!void {
    var held_rows: u64 = 0;
    var rows = self.imports.rows.iterator();
    while (rows.next()) |entry| {
        const row = entry.value_ptr.*;
        if (row.count == 0) return error.ImportRowRetainsNothing;
        if (row.session_held > row.count) return error.SessionHeldExceedsCount;
        if (row.held_back > row.session_held) return error.HeldBackExceedsSessionHeld;
        if (row.resolution_holds == 0 and row.held_back != 0) return error.HeldBackWithoutHold;
        if (row.resolution_holds != 0) held_rows += 1;
    }
    if (held_rows != self.imports.held_rows) return error.HeldRowsMiscounted;
    const identities = self.imports.identities orelse return;
    var it = identities.iterator();
    while (it.next()) |entry| {
        // The bootstrap import is held by right of the session, with an
        // identity and no row (`ImportTable.identities`).
        if (entry.key_ptr.* == session.bootstrap_position) continue;
        const row = self.imports.rows.get(entry.key_ptr.*) orelse return error.IdentityWithoutImport;
        if (entry.value_ptr.lifted_retains > row.count) return error.LiftedRetainsExceedCount;
    }
}

fn auditLocalPromises(self: *const Session) Violation!void {
    var exported: usize = 0;
    var exports = self.exports.iterator();
    while (exports.next()) |entry| {
        if (entry.row.purpose == .local_promise_answer) exported += 1;
    }
    const registry = self.local_promises orelse {
        if (exported != 0) return error.ProjectionsMiscounted;
        return;
    };
    if (registry.projections.items.len != exported) return error.ProjectionsMiscounted;
    var deferred: u32 = 0;
    for (registry.projections.items) |position| {
        const purpose = self.exports.purpose(position) orelse return error.ProjectionWithoutExport;
        if (purpose != .local_promise_answer) return error.ProjectionWithoutExport;
        if (purpose.local_promise_answer.settlement_deferred) deferred += 1;
    }
    if (deferred != registry.deferred) return error.DeferredSettlementsMiscounted;
}

/// What the payloads the session can reach hold against its counters. A
/// payload a carrier or a Host promise alone holds is out of reach, and the
/// retained-answer counter also charges import release batches, so the Host
/// promise and resolution sums are floors under their counters. Calls queue
/// only on a pending payload, which a row always reaches, so the queued call
/// bytes match exactly.
const PayloadSums = struct {
    host_promises: u64 = 0,
    resolution_bytes: u64 = 0,
    queued_call_bytes: u64 = 0,

    fn take(self: *PayloadSums, payload: *const answers.AnswerPayload) Violation!void {
        if (payload.host_promise != 0) {
            self.host_promises += 1;
        } else if (payload.host_promise_notified) return error.HostPromiseNotifiedWithoutMark;
        self.resolution_bytes += payload.resolution_charge;
        for (payload.queue.items) |call| self.queued_call_bytes += call.charge;
    }
};

fn auditAnswerPayloads(self: *const Session) Violation!void {
    var sums: PayloadSums = .{};
    var inbound = self.inbound_answers.rows.valueIterator();
    while (inbound.next()) |cell| if (cell.payload) |payload| try sums.take(payload);
    if (self.detached_inbound_answers) |store| {
        var detached = store.rows.valueIterator();
        while (detached.next()) |row| try sums.take(row.payload);
    }
    var outbound = self.outbound_answers.iterator();
    while (outbound.next()) |entry| if (entry.cell.payload) |payload| try sums.take(payload);
    if (sums.host_promises > self.inbound_answers.host_promises) return error.HostPromisesUndercounted;
    if (sums.resolution_bytes > self.retained_sent_answer_bytes) return error.ResolutionBytesUndercounted;
    if (sums.queued_call_bytes != self.queued_call_bytes) return error.QueuedCallBytesMiscounted;
}
