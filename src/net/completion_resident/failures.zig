//! A connection keeps failures in observation order until a snapshot or an
//! awaited write close claims them. Read and write admission have their own
//! states, so consuming a report never reopens a refused direction.

const foundation = @import("foundation");
const completion = @import("../completion/loop.zig");
const carrier_failure = @import("../carrier_failure.zig");

const Report = carrier_failure.Report;
/// Position of the shared terminal I/O cause in this connection's report.
const Latch = enum(u3) { unseen, primary, secondary, later, reported };

/// The compact report needs at most three resident observations: a refused
/// receive, a refused staging append, and the physical send of admitted
/// bytes. Borrowed names and nested consequences live in the cold map.
pub const Pending = packed struct {
    third: bool = false,
    latch: Latch = .unseen,
    detailed: bool = false,
    write: enum(u2) { open, failed, reported } = .open,

    pub fn needsDetail(self: Pending) bool {
        return !self.detailed and switch (self.latch) {
            .primary, .secondary, .later => true,
            .unseen, .reported => false,
        };
    }

    fn scalars(self: Pending, causes: [2]?anyerror) ?Report {
        var chain = foundation.FailureChain.init(causes[0] orelse return null);
        chain.secondary_cause = causes[1];
        chain.secondary_count = @as(u16, @intFromBool(causes[1] != null)) + @intFromBool(self.third);
        return .{ .chain = chain };
    }
};

pub fn readFailed(self: anytype, id: usize, conn: anytype, cause: anyerror, comp: ?completion.Completion) void {
    observe(self, id, conn, cause, comp);
    conn.recv = .failed;
}

pub fn writeFailed(self: anytype, id: usize, conn: anytype, cause: anyerror, comp: ?completion.Completion) void {
    if (comp != null and comp.?.failure_origin == .terminal_io and conn.failures.latch == .reported) {
        if (conn.failures.write == .open) conn.failures.write = .reported;
        return;
    }
    conn.failures.write = .failed;
    observe(self, id, conn, cause, comp);
}

/// Borrowed carrier detail belongs to the primary it describes.
fn borrowedReport(comp: completion.Completion, cause: anyerror) ?Report {
    const borrowed = comp.borrowed;
    if (borrowed.carrierFailureValue()) |failure|
        return .{ .chain = failure.chain, .phase = failure.phase, .detail = failure.detail };
    if (borrowed.failureChain()) |chain| return .{ .chain = chain.*, .phase = borrowed.carrierPhase() };
    if (borrowed.carrierPhase()) |phase| return .{ .chain = .init(cause), .phase = phase };
    return null;
}

pub fn refineLatch(self: anytype, id: usize, conn: anytype, comp: completion.Completion) void {
    if (!conn.failures.needsDetail()) return;
    const detail = borrowedReport(comp, comp.failure orelse error.ConnectionLost) orelse return;
    const slot = richSlot(self, id, conn) orelse return;
    splice(slot, conn.failures.latch, detail, .refine);
    conn.failures.detailed = comp.borrowed.failureChain() != null;
}

/// Allocate only for borrowed detail. Under pressure the row retains its scalar history.
fn richSlot(self: anytype, id: usize, conn: anytype) ?*Report {
    // best-effort: a refused rich slot leaves the scalar causes on the row.
    const slot = self.conn_failures.getOrPut(self.allocator, id) catch return null;
    if (!slot.found_existing) {
        if (conn.failures.scalars(conn.failure_causes)) |prior| slot.value_ptr.* = prior;
    }
    return slot.value_ptr;
}

fn observe(self: anytype, id: usize, conn: anytype, cause: anyerror, comp: ?completion.Completion) void {
    const pending = &conn.failures;
    const marked = if (comp) |value| value.failure_origin == .terminal_io else false;
    if (marked and pending.latch != .unseen) {
        refineLatch(self, id, conn, comp.?);
        return;
    }
    const borrowed = if (comp) |value| borrowedReport(value, cause) else null;
    const rich = if (borrowed != null) richSlot(self, id, conn) else self.conn_failures.getPtr(id);
    if (marked) {
        pending.latch = if (conn.failure_causes[0] == null)
            .primary
        else if (conn.failure_causes[1] == null and (rich == null or rich.?.chain.secondary_count == 0))
            .secondary
        else
            .later;
        pending.detailed = rich != null and comp.?.borrowed.failureChain() != null;
    }
    if (rich) |slot| {
        const next = borrowed orelse Report.init(cause);
        if (conn.failure_causes[0] == null) slot.* = next else slot.chain.noteChain(next.chain);
    }
    for (&conn.failure_causes) |*slot| {
        if (slot.* == null) {
            slot.* = cause;
            return;
        }
    }
    pending.third = true;
}

pub fn claim(self: anytype, id: usize, conn: anytype) ?Report {
    const pending = &conn.failures;
    const kept = self.conn_failures.fetchRemove(id);
    var report = if (kept) |entry| @as(?Report, entry.value) else pending.scalars(conn.failure_causes);
    if (comptime @hasDecl(@TypeOf(self.backend), "takeConnFailure")) {
        const live = conn.close == .open;
        const prior = if (live or report != null) self.backend.takeConnFailure(conn.fd, .independent) else null;
        const owes_terminal = pending.latch != .reported and (live or pending.latch != .unseen);
        const exact = if (owes_terminal) self.backend.takeConnFailure(conn.fd, .terminal_io) else null;
        switch (pending.latch) {
            .unseen, .reported => {
                if (prior) |earlier| foundation.latchFailure(&report, earlier);
                if (exact) |terminal| foundation.latchFailure(&report, terminal);
            },
            .primary, .secondary, .later => {
                if (exact) |terminal| {
                    if (!pending.detailed) {
                        splice(&report.?, pending.latch, terminal, .refine);
                    } else if (pending.latch == .primary) fillCarrier(&report.?, terminal);
                }
                if (prior) |earlier| splice(&report.?, pending.latch, earlier, .insert);
            },
        }
        if (exact != null) pending.latch = .reported;
    }
    const result = report orelse return null;
    conn.failure_causes = .{ null, null };
    pending.* = .{
        .latch = if (pending.latch == .unseen) .unseen else .reported,
        .write = if (pending.write == .open) .open else .reported,
    };
    return result;
}

/// Refine a scalar in place, or insert an earlier independent report at its
/// position. Only the primary owns carrier detail. Only the first two causes
/// have names in a bounded chain.
fn splice(report: *Report, position: Latch, incoming: Report, mode: enum { refine, insert }) void {
    switch (position) {
        .primary => {
            const previous = report.*;
            if (mode == .insert) {
                report.* = incoming;
                report.chain.noteChain(previous.chain);
            } else {
                fillCarrier(report, incoming);
                report.chain = incoming.chain;
                if (previous.chain.secondary_cause) |cause| report.chain.noteChain(.{
                    .cause = cause,
                    .cause_name = previous.chain.secondary_cause_name,
                    .classification = previous.chain.secondary_classification,
                    .secondary_count = previous.chain.secondary_count - 1,
                });
            }
        },
        .secondary, .later => {
            if (position == .secondary) {
                report.chain.secondary_cause = incoming.chain.cause;
                report.chain.secondary_cause_name = incoming.chain.cause_name;
                report.chain.secondary_classification = incoming.chain.classification;
            }
            report.chain.secondary_count +|= @intFromBool(mode == .insert);
            report.chain.secondary_count +|= incoming.chain.secondary_count;
        },
        .reported, .unseen => unreachable,
    }
}

/// Two observations of the same primary can name different carrier fields.
fn fillCarrier(first: *Report, other: Report) void {
    first.phase = first.phase orelse other.phase;
    first.detail.engine_code = first.detail.engine_code orelse other.detail.engine_code;
    first.detail.peer_alert = first.detail.peer_alert orelse other.detail.peer_alert;
    first.detail.verification_flags |= other.detail.verification_flags;
}
